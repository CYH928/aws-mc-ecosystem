#!/bin/bash
# ============================================================
# Minecraft World Restore from S3
# Usage: sudo bash mc_restore.sh [backup-filename]
# Example: sudo bash mc_restore.sh mc-backup-20240101-1200.tar.gz
# No argument = interactive list to choose from
# ============================================================
set -euo pipefail

# ── Config (auto-detected from instance metadata) ─────────────────────────
# Find world data in Pterodactyl volumes dynamically
MC_DIR=$(find /var/lib/pterodactyl/volumes/ -maxdepth 2 -name "server.properties" -printf "%h\n" 2>/dev/null | head -1)
if [ -z "$MC_DIR" ]; then
  MC_DIR=$(ls -d /var/lib/pterodactyl/volumes/*/ 2>/dev/null | head -1)
fi
if [ -z "$MC_DIR" ]; then
  echo "ERROR: Could not find Pterodactyl server volume."
  echo "Check /var/lib/pterodactyl/volumes/"
  exit 1
fi
echo "Found server directory: ${MC_DIR}"
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
BACKUP_BUCKET=$(cat /etc/mc-backup-bucket 2>/dev/null || echo "")

if [ -z "$BACKUP_BUCKET" ]; then
  echo "ERROR: Could not determine backup bucket."
  echo "Set it manually: export BACKUP_BUCKET=your-bucket-name"
  echo "Or: echo 'your-bucket-name' > /etc/mc-backup-bucket"
  exit 1
fi

# ── Choose backup ──────────────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
  CHOSEN_BACKUP="$1"
else
  echo "Fetching available backups from s3://${BACKUP_BUCKET}/backups/ ..."
  echo ""

  mapfile -t BACKUPS < <(aws s3 ls "s3://${BACKUP_BUCKET}/backups/" \
    --region "$AWS_REGION" \
    | awk '{print $4}' \
    | sort -r \
    | head -20)

  if [ ${#BACKUPS[@]} -eq 0 ]; then
    echo "No backups found in s3://${BACKUP_BUCKET}/backups/"
    exit 1
  fi

  echo "Available backups (newest first):"
  for i in "${!BACKUPS[@]}"; do
    echo "  [$((i+1))] ${BACKUPS[$i]}"
  done
  echo ""
  read -rp "Choose backup number [1-${#BACKUPS[@]}]: " CHOICE
  CHOSEN_BACKUP="${BACKUPS[$((CHOICE-1))]}"
fi

echo ""
echo "Selected: ${CHOSEN_BACKUP}"
read -rp "WARNING: This will overwrite current world data. Continue? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Stop Minecraft server (Pterodactyl Docker containers) ─────────────────
echo "Stopping Minecraft server (Docker containers)..."
sudo docker stop $(sudo docker ps -q) 2>/dev/null || true
sleep 5

# ── Backup current world (safety) ─────────────────────────────────────────
SAFETY_DATE=$(date +%Y%m%d-%H%M)
echo "Creating safety backup of current world -> /tmp/world-before-restore-${SAFETY_DATE}.tar.gz"
tar -czf "/tmp/world-before-restore-${SAFETY_DATE}.tar.gz" \
  -C "$MC_DIR" world world_nether world_the_end 2>/dev/null || \
tar -czf "/tmp/world-before-restore-${SAFETY_DATE}.tar.gz" -C "$MC_DIR" world
echo "Safety backup saved to /tmp/world-before-restore-${SAFETY_DATE}.tar.gz"

# ── Download from S3 ───────────────────────────────────────────────────────
echo "Downloading s3://${BACKUP_BUCKET}/backups/${CHOSEN_BACKUP} ..."
aws s3 cp "s3://${BACKUP_BUCKET}/backups/${CHOSEN_BACKUP}" \
  "/tmp/${CHOSEN_BACKUP}" \
  --region "$AWS_REGION"

# ── Remove old world data ──────────────────────────────────────────────────
echo "Removing old world data..."
rm -rf "$MC_DIR/world" "$MC_DIR/world_nether" "$MC_DIR/world_the_end"

# ── Extract ────────────────────────────────────────────────────────────────
echo "Extracting backup..."
tar -xzf "/tmp/${CHOSEN_BACKUP}" -C "$MC_DIR"
chown -R pterodactyl:pterodactyl "$MC_DIR" 2>/dev/null || chown -R 988:988 "$MC_DIR"

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -f "/tmp/${CHOSEN_BACKUP}"

# ── Start Minecraft server (restart Wings to pick up changes) ─────────────
echo "Restarting Wings to start Minecraft server..."
systemctl restart wings

echo ""
echo "======================================================"
echo " Restore complete: ${CHOSEN_BACKUP}"
echo " Safety backup at: /tmp/world-before-restore-${SAFETY_DATE}.tar.gz"
echo "======================================================"
