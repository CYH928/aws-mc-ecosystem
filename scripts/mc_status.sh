#!/bin/bash
# ============================================================
# Minecraft Server Status Check
# Usage: bash mc_status.sh
# Run on EITHER the watcher or MC server
# ============================================================

AWS_REGION=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "ap-east-1")

echo "======================================================"
echo " Minecraft Server Status"
echo " $(date)"
echo "======================================================"

# ── Detect which machine we're on ─────────────────────────────────────────
INSTANCE_NAME=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/tags/instance/Name 2>/dev/null || echo "unknown")

# ── MC Server EC2 state ────────────────────────────────────────────────────
echo ""
echo "[EC2 Instances]"

MC_INFO=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=minecraft-server" \
  --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,PrivateIP:PrivateIpAddress,Type:InstanceType,LaunchTime:LaunchTime}' \
  --output json 2>/dev/null)

MC_STATE=$(echo "$MC_INFO" | jq -r '.State // "unknown"')
MC_PUBLIC_IP=$(echo "$MC_INFO" | jq -r '.IP // "none"')
MC_LAUNCH=$(echo "$MC_INFO" | jq -r '.LaunchTime // "N/A"')

echo "  MC Server  : ${MC_STATE}"
echo "  Public IP  : ${MC_PUBLIC_IP}"
echo "  Started at : ${MC_LAUNCH}"

WATCHER_INFO=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=minecraft-watcher" \
  --query 'Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress}' \
  --output json 2>/dev/null)

WATCHER_STATE=$(echo "$WATCHER_INFO" | jq -r '.State // "unknown"')
WATCHER_IP=$(echo "$WATCHER_INFO" | jq -r '.IP // "none"')

echo "  Watcher    : ${WATCHER_STATE} (${WATCHER_IP})"

# ── Minecraft process (only works on MC machine) ───────────────────────────
echo ""
echo "[Minecraft Server (Pterodactyl/Docker)]"
RUNNING_CONTAINERS=$(sudo docker ps -q 2>/dev/null | wc -l)
if [ "$RUNNING_CONTAINERS" -gt 0 ]; then
  echo "  Docker containers : ${RUNNING_CONTAINERS} RUNNING"

  # Player list via RCON
  RCON_PASS=$(find /var/lib/pterodactyl/volumes/ -name "server.properties" -exec grep "rcon.password" {} \; 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')
  if [ -n "${RCON_PASS:-}" ] && command -v mcrcon &>/dev/null; then
    PLAYER_LIST=$(mcrcon -H localhost -P 25575 -p "$RCON_PASS" "list" 2>/dev/null || echo "RCON unavailable")
    echo "  Players           : ${PLAYER_LIST}"

    TPS=$(mcrcon -H localhost -P 25575 -p "$RCON_PASS" "tps" 2>/dev/null || echo "N/A")
    echo "  TPS               : ${TPS}"
  fi
else
  echo "  Docker containers : NONE RUNNING (or not on MC machine)"
fi

# ── System resources (only on MC machine) ─────────────────────────────────
echo ""
echo "[System Resources]"
if command -v free &>/dev/null; then
  RAM_USED=$(free -h | awk '/^Mem:/ {print $3}')
  RAM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
  echo "  RAM : ${RAM_USED} / ${RAM_TOTAL}"
fi

CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
echo "  CPU load avg : ${CPU_LOAD}"

DISK=$(df -h /var/lib/pterodactyl/volumes 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}' || echo "N/A")
echo "  Disk (world) : ${DISK}"

# ── Recent backup status ───────────────────────────────────────────────────
echo ""
echo "[Last Backup]"
BUCKET=$(cat /etc/mc-backup-bucket 2>/dev/null || echo "")
if [ -n "$BUCKET" ]; then
  LAST_BACKUP=$(aws s3 ls "s3://${BUCKET}/backups/" \
    --region "$AWS_REGION" 2>/dev/null \
    | sort | tail -1 | awk '{print $1, $2, $4}')
  echo "  ${LAST_BACKUP:-No backups found}"
else
  echo "  Bucket not configured (run on MC machine)"
fi

# ── mc-proxy (only on Watcher) ────────────────────────────────────────────
echo ""
echo "[Watcher Proxy Service]"
if systemctl is-active --quiet mc-proxy 2>/dev/null; then
  echo "  mc-proxy : RUNNING"
else
  echo "  mc-proxy : STOPPED (or not on Watcher)"
fi

echo ""
echo "======================================================"
