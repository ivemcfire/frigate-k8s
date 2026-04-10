# Frigate NVR on Kubernetes

Production-grade deployment of [Frigate NVR](https://frigate.video/) on a bare-metal K3s cluster with hardware-accelerated video processing, automated backups, secure secret management, and a custom write-back sidecar for UI-driven configuration management.

## Architecture

```
                    Internet
                       |
                 Cloudflare Tunnel
                       |
              cams.ayurforlife.eu
                       |
         +-------------+-------------+
         |        K3s Cluster        |
         |                           |
         |   +-------------------+   |
         |   |   Frigate Pod     |   |
         |   |                   |   |
         |   |  +-----------+   |   |
         |   |  |  Frigate  |   |   |        +------------------+
         |   |  |  (0.17)   |---+---+------->| 8x IP Cameras    |
         |   |  +-----------+   |   |  RTSP  | XMeye / Reolink  |
         |   |  |config-sync|   |   |        | Yi-hack / Annke   |
         |   |  |  sidecar  |   |   |        +------------------+
         |   |  +-----------+   |   |
         |   +-------------------+   |
         |            |              |
         |    +-------+-------+      |
         |    |               |      |
         |  hostPath     2TB USB     |
         |  (config/DB)  (recordings)|
         |                           |
         +---------------------------+
                    |
              Nightly rsync
                    |
            Offsite Jumphost
```

**Cluster:** 1x Intel i5-1035G1 control plane + 3x ARM64 phone workers (OnePlus 6/6T running postmarketOS)

## Key Features

### Write-Back Sidecar Pattern
A custom sidecar container that bridges the gap between Kubernetes declarative state and Frigate's imperative UI configuration:

- **Init container** seeds the config from a ConfigMap on first boot
- **Frigate** reads/writes config natively via its Web UI
- **Sidecar** polls for changes and syncs them back to the Kubernetes API
- The ConfigMap stays in sync without pod restarts -- Frigate handles its own reload

This pattern solves the "split-brain" problem where Kubernetes and the application UI both want to own configuration. It's a lightweight alternative to building a full Kubernetes Operator.

```
User clicks "Save" in UI
        |
        v
Frigate writes to /config/config.yml (hostPath)
        |
        v
Sidecar detects change (md5 polling, 5s interval)
        |
        v
kubectl create configmap --dry-run=client | kubectl apply
        |
        v
Kubernetes API updated (no pod restart triggered)
```

### Hardware-Accelerated Video Pipeline
- Intel QSV (VA-API) hardware decode for H.264/H.265 streams
- GPU passthrough via privileged container with `/dev/dri` mount
- CPU-based TensorFlow Lite inference for object detection
- Separate decode and detect resolution strategies per camera tier

### Secret Management
RTSP credentials never touch disk, ConfigMaps, or Git history:

- Passwords stored in Kubernetes Secrets
- Injected as environment variables at runtime
- Frigate's native `{ENV_VAR}` substitution resolves them in-memory
- Config files use placeholders: `rtsp://admin:{FRIGATE_REOLINK_PASSWORD}@...`

### Automated Backup Pipeline
A Kubernetes CronJob runs nightly `rsync` to an offsite jumphost:

- Incremental transfers (only new/changed files)
- Mirrors deletions to prevent backup bloat
- SSH key authentication via mounted K8s Secret
- 4-hour safety timeout for large syncs

### Zero-Trust External Access
Cloudflare Tunnel exposes the Web UI without opening inbound firewall ports:

- No port forwarding or public IP required
- TLS termination at Cloudflare edge
- Tunnel credentials stored as K8s Secrets

### Face Recognition Pipeline
Frigate 0.17 built-in face recognition with compute-aware filtering:

- `min_area` threshold calculated from detect stream resolution
- Effectively limits face recognition to high-res cameras only
- Low-res streams (640x480) produce face crops below threshold -- filtered automatically

## DevOps Practices

| Practice | Implementation |
|----------|---------------|
| **Infrastructure as Code** | All manifests version-controlled, `kubectl apply` is the only deployment method |
| **Secret Hygiene** | K8s Secrets + env var substitution, `.gitignore` for local secret files, zero credentials in git history |
| **Least Privilege RBAC** | Sidecar ServiceAccount scoped to single ConfigMap with `get/patch/update` only |
| **Resource Management** | CPU requests without limits (compressible), memory limits enforced (incompressible) |
| **Backup & DR** | Nightly rsync CronJob to offsite host, SSH key auth, idempotent incremental sync |
| **Stable Networking** | MetalLB LoadBalancer with pinned IP annotation for deterministic service addressing |
| **Node Affinity** | GPU workloads pinned to capable nodes via `nodeSelector` |
| **Observability** | Prometheus exporter sidecar (`frigate-exporter`) + Grafana dashboards |

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

## License

MIT
