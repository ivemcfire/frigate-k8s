# Frigate NVR on Kubernetes

Production-grade deployment of [Frigate NVR](https://frigate.video/) on a bare-metal K3s cluster with hardware-accelerated video processing, a custom write-back sidecar for UI-driven configuration management, automated offsite backups, and zero-trust external access.

## Architecture

```
                        Internet
                           |
                     Cloudflare Tunnel (zero inbound ports)
                           |
                  cams.ayurforlife.eu
                           |
    +----------------------+----------------------+
    |                  K3s Cluster                 |
    |                                              |
    |   k3master (Intel i5-1035G1, 16GB)           |
    |   +--------------------------------------+   |
    |   |           Frigate Pod                |   |         8x IP Cameras
    |   |  +----------+ +---------------+      |   |    +--------------------+
    |   |  |  Frigate  | | config-sync  |      |   |    | cam01-06: XMeye    |
    |   |  |  (0.17)   | |   sidecar    |      |<--+--->| 720p main/480p sub |
    |   |  +----------+ +------+--------+      |   |    |                    |
    |   |       |               |              |   |    | cam07: Reolink 4K  |
    |   |   Intel QSV           |              |   |    | H.265 main/sub     |
    |   |   HW decode      K8s API             |   |    |                    |
    |   |       |          (ConfigMap           |   |    | cam08: Yi-hack     |
    |   |   TFLite CPU      write-back)        |   |    | 1080p main/480p sub|
    |   |   detection                          |   |    +--------------------+
    |   +--------------------------------------+   |          RTSP/TCP
    |        |                    |                 |
    |    hostPath             hostPath              |
    |   /mnt/frigate/        /mnt/frigate/          |
    |     config/              (2TB USB)            |
    |   (DB + config)        (recordings)           |
    |        |                                      |
    |   +----+----+    +-----------------------+    |
    |   |Mosquitto|    | 3x ARM64 Phone Nodes  |   |
    |   | (MQTT)  |    | OnePlus 6/6T          |   |
    |   +---------+    | postmarketOS / musl    |   |
    |                  | (edge compute workers) |   |
    |                  +-----------------------+    |
    +-------+------------------------------------------+
            |
      Nightly rsync (CronJob, SSH key auth)
            |
      Offsite Jumphost (DR backup)
```

**Cluster:** 1x Intel i5-1035G1 control plane + 3x ARM64 phone workers (OnePlus 6/6T running postmarketOS)

## Key Features

### Write-Back Sidecar -- A Lightweight Kubernetes Operator

The core engineering challenge: Kubernetes manages state declaratively (ConfigMaps), but Frigate's Web UI manages state imperatively (file writes). Running both creates a split-brain problem.

The solution is a custom write-back sidecar that bridges UI-driven configuration changes back to the Kubernetes API, allowing non-technical users to drive application state through the UI while preserving Infrastructure as Code auditing on the cluster side.

```
User clicks "Save" in Frigate UI
        |
        v
Frigate writes to /config/config.yml (writable hostPath)
Frigate gracefully reloads its own video pipeline
        |
        v
config-sync sidecar detects file change (md5 polling, 5s)
        |
        v
Sidecar authenticates with K8s API via scoped ServiceAccount
        |
        v
kubectl create configmap --dry-run=client | kubectl apply
        |
        v
Kubernetes ConfigMap updated -- cluster state matches UI state
(no pod restart -- Frigate already reloaded internally)
```

**Init container** handles first-boot seeding: copies the ConfigMap (the IaC baseline) onto the writable hostPath. On subsequent restarts, the existing config is preserved. This ensures the ConfigMap is the initial source of truth, but the UI takes over for day-to-day operations.

**RBAC:** The sidecar's ServiceAccount is scoped to a single ConfigMap (`frigate-config`) with only `get/patch/update` verbs -- least-privilege access to the Kubernetes API.

### Dual-Stream Video Routing

Camera bandwidth is managed at the hardware level to prevent backbone saturation:

- **Main streams** (720p-4K, H.264/H.265 CBR) are routed strictly to disk for recording
- **Sub-streams** (640x480) are routed to the detection engine for AI inference
- Frigate never decodes the main stream for detection -- only the sub-stream
- Exception: cam07 (Reolink 4K) uses its main stream for detection, downscaled to 1280x720 via Intel QSV to enable face recognition at sufficient resolution

### Hardware-Accelerated Video Pipeline

- **Decode:** Intel QSV (VA-API) hardware decode for H.264/H.265 via `/dev/dri` passthrough
- **Detection:** CPU-based TensorFlow Lite inference (4 threads) for real-time object detection
- **Face recognition:** Frigate 0.17 built-in pipeline with `min_area` threshold tuned per camera tier -- effectively limits face matching to high-resolution streams only, saving compute on low-res feeds

### Secret Management

RTSP credentials exist only in memory at runtime -- never on disk, in ConfigMaps, or in Git history:

- Passwords stored in Kubernetes Secrets
- Injected as environment variables into the container
- Frigate's native `{ENV_VAR}` substitution resolves them in-memory at config parse time
- Config files and Git history contain only placeholders: `rtsp://admin:{FRIGATE_REOLINK_PASSWORD}@...`

### Automated Backup Pipeline

A Kubernetes CronJob runs nightly incremental `rsync` to an offsite jumphost:

- Transfers only new/changed files (incremental sync)
- `--delete` mirrors Frigate's retention policy purges to prevent backup bloat
- SSH key authentication via mounted K8s Secret (no passwords)
- 4-hour `activeDeadlineSeconds` safety timeout for large syncs
- `concurrencyPolicy: Forbid` prevents overlapping backup runs

### Zero-Trust External Access

Cloudflare Tunnel exposes the Web UI without opening any inbound firewall ports:

- No port forwarding, no public IP, no DMZ
- TLS termination at Cloudflare edge
- Tunnel credentials stored as K8s Secrets
- Routes both Frigate (`cams.`) and Grafana (`monitor.`) through a single tunnel

## DevOps Practices

| Practice | Implementation |
|----------|---------------|
| **Infrastructure as Code** | All manifests version-controlled, `kubectl apply` is the only deployment path |
| **Secret Hygiene** | K8s Secrets + native env var substitution, zero credentials in Git history |
| **Least Privilege RBAC** | Sidecar ServiceAccount scoped to single ConfigMap with `get/patch/update` only |
| **Resource Management** | CPU requests without limits (compressible), memory limits enforced (incompressible) |
| **Backup & DR** | Nightly rsync CronJob to offsite host, SSH key auth, idempotent incremental sync |
| **Stable Networking** | MetalLB LoadBalancer with pinned IP annotation for deterministic service addressing |
| **Node Affinity** | GPU workloads pinned to capable nodes via `nodeSelector` |
| **Observability** | Prometheus exporter (`frigate-exporter`) + Grafana dashboards via Cloudflare Tunnel |
| **Heterogeneous Cluster** | Mixed amd64/arm64 architecture -- control plane on Intel, edge workloads on ARM64 phones |

## Manifest Structure

```
frigate-k8s/
  namespace.yaml        # frigate namespace
  configmap.yaml        # Frigate config (seed template with env var placeholders)
  deployment.yaml       # Main pod: init container + Frigate + config-sync sidecar
  service.yaml          # LoadBalancer with MetalLB pinned IP
  rbac.yaml             # ServiceAccount, Role, RoleBinding for sidecar
  cloudflared.yaml      # Cloudflare Tunnel deployment + config
  backup-cronjob.yaml   # Nightly rsync to offsite backup
  backup-frigate.sh     # Backup script
```

## Quick Start

```bash
# Create namespace
kubectl apply -f namespace.yaml

# Create secrets (not tracked in git)
kubectl create secret generic frigate-rtsp-creds \
  --from-literal=reolink-password='YOUR_PASSWORD' -n frigate

# Deploy everything
kubectl apply -f configmap.yaml
kubectl apply -f rbac.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f cloudflared.yaml
kubectl apply -f backup-cronjob.yaml
```

## Requirements

- K3s or K8s cluster with a node that has an Intel iGPU (VA-API support)
- MetalLB or equivalent LoadBalancer controller
- Cloudflare account with a configured tunnel (for external access)
- Offsite host with SSH access (for backup CronJob)

## Related Projects

This repo is part of a larger homelab infrastructure running on the same K3s cluster:

- **GPU inference pipeline** -- YOLOv8 object detection on Snapdragon 845 (Adreno 630 GPU) via ONNX Runtime + OpenCL, coordinated over MQTT
- **Monitoring stack** -- Prometheus + Grafana + Loki on ARM64 nodes

## License

MIT
