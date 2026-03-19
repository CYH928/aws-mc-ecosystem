#!/bin/bash
set -euo pipefail

BACKUP_BUCKET="${backup_bucket}"
AWS_REGION="${aws_region}"
RCON_PASSWORD="${rcon_password}"

# Save config for scripts
echo "$${BACKUP_BUCKET}" > /etc/mc-backup-bucket

# ── System update ──────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y openjdk-21-jre-headless curl jq unzip

# Install AWS CLI v2
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Install mcrcon (RCON client for auto-stop and backup scripts)
curl -sL "https://github.com/Tiiffi/mcrcon/releases/download/v0.7.2/mcrcon-0.7.2-linux-x86-64.tar.gz" \
  | tar -xz -C /usr/local/bin/ mcrcon
chmod +x /usr/local/bin/mcrcon

# NOTE: Minecraft server is NOT managed by systemd.
# Pterodactyl Panel + Wings + Docker manages all MC server processes.
# Install Pterodactyl manually after first boot (see scripts/install_pterodactyl.sh).

# ── Auto-stop: 0 players for 15 min → stop this EC2 ──────────────────────
cat > /usr/local/bin/mc-autostop.sh << 'STOPEOF'
#!/bin/bash
RCON_PASS="__RCON_PASSWORD__"
AWS_REGION_VAL="__AWS_REGION__"
COUNTER_FILE=/tmp/mc_empty_count

# Check if any Docker container (Pterodactyl server) is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

RESPONSE=$(mcrcon -H localhost -P 25575 -p "$RCON_PASS" "list" 2>/dev/null || echo "error")

if echo "$RESPONSE" | grep -q "There are 0"; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  COUNT=$((COUNT + 1))
  echo $COUNT > "$COUNTER_FILE"
  echo "$(date): No players (${COUNT}/3 checks before shutdown)"
  if [ "$COUNT" -ge 3 ]; then
    echo "$(date): 15 min empty - stopping instance"
    rm -f "$COUNTER_FILE"
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    /usr/local/bin/aws ec2 stop-instances --region "$AWS_REGION_VAL" --instance-ids "$INSTANCE_ID"
  fi
else
  rm -f "$COUNTER_FILE"
fi
STOPEOF

sed -i "s/__RCON_PASSWORD__/$${RCON_PASSWORD}/" /usr/local/bin/mc-autostop.sh
sed -i "s/__AWS_REGION__/$${AWS_REGION}/" /usr/local/bin/mc-autostop.sh
chmod +x /usr/local/bin/mc-autostop.sh

# ── S3 Backup: every hour ─────────────────────────────────────────────────
cat > /usr/local/bin/mc-backup.sh << BAKEOF
#!/bin/bash
DATE=\$(date +%Y%m%d-%H%M)
BUCKET="$${BACKUP_BUCKET}"
REGION="$${AWS_REGION}"

# Find Pterodactyl server volume (world is managed by Pterodactyl Docker)
MC_DIR=\$(find /var/lib/pterodactyl/volumes -maxdepth 2 -name "world" -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "\$MC_DIR" ]; then
  echo "\$(date): No world directory found in Pterodactyl volumes, skipping backup"
  exit 0
fi

/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-off" 2>/dev/null || true
/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-all" 2>/dev/null || true
sleep 5

tar -czf /tmp/mc-backup-\$DATE.tar.gz \
  -C "\$MC_DIR" world world_nether world_the_end 2>/dev/null || \
tar -czf /tmp/mc-backup-\$DATE.tar.gz -C "\$MC_DIR" world

/usr/local/bin/aws s3 cp /tmp/mc-backup-\$DATE.tar.gz \
  "s3://\$BUCKET/backups/mc-backup-\$DATE.tar.gz" \
  --region "\$REGION"

rm -f /tmp/mc-backup-\$DATE.tar.gz

/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-on" 2>/dev/null || true
echo "\$(date): Backup \$DATE uploaded to s3://\$BUCKET"
BAKEOF
chmod +x /usr/local/bin/mc-backup.sh

# Check every 1 min (auto-stop after 3 min idle), backup every hour
(crontab -l 2>/dev/null; \
  echo "*/1 * * * * /usr/local/bin/mc-autostop.sh >> /var/log/mc-autostop.log 2>&1"; \
  echo "0 * * * * /usr/local/bin/mc-backup.sh >> /var/log/mc-backup.log 2>&1") | crontab -

echo "MC server base setup complete."
echo "Next: install Pterodactyl (scripts/install_pterodactyl.sh)"
