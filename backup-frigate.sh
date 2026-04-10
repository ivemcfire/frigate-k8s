#!/bin/bash
# Nightly backup of Frigate config DB to jumphost
# Source: /mnt/frigate/config on k3master (hostPath)
# Destination: user@192.168.100.152:/home/user/backups/frigate/
# Retains 30 daily backups

set -euo pipefail

SRC="/mnt/frigate/config"
DEST_HOST="user@192.168.100.152"
DEST_DIR="/home/user/backups/frigate"
DATE=$(date +%Y-%m-%d_%H%M)
ARCHIVE="frigate-config-${DATE}.tar.gz"
KEEP_DAYS=30

echo "[$(date)] Starting Frigate config backup..."

# Create compressed archive (exclude model_cache — can be re-downloaded)
tar czf "/tmp/${ARCHIVE}" -C "${SRC}" \
  --exclude='model_cache' \
  .

# Transfer to jumphost
scp -o ConnectTimeout=10 "/tmp/${ARCHIVE}" "${DEST_HOST}:${DEST_DIR}/${ARCHIVE}"

# Clean up local temp
rm -f "/tmp/${ARCHIVE}"

# Purge backups older than KEEP_DAYS on jumphost
ssh -o ConnectTimeout=10 "${DEST_HOST}" \
  "find ${DEST_DIR} -name 'frigate-config-*.tar.gz' -mtime +${KEEP_DAYS} -delete"

echo "[$(date)] Backup complete: ${ARCHIVE}"
