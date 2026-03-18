#!/bin/bash
set -euo pipefail

BACKUP_BUCKET="${backup_bucket}"
AWS_REGION="${aws_region}"
MC_VERSION="${mc_version}"
RCON_PASSWORD="${rcon_password}"
MC_DIR=/home/minecraft/server

# Save bucket name so mc_restore.sh can auto-detect it
echo "$${BACKUP_BUCKET}" > /etc/mc-backup-bucket

# ── System update ──────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y openjdk-21-jre-headless curl jq unzip screen

# Install AWS CLI v2
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Install mcrcon (RCON client for player count checks)
curl -sL "https://github.com/Tiiffi/mcrcon/releases/download/v0.7.2/mcrcon-0.7.2-linux-x86-64.tar.gz" \
  | tar -xz -C /usr/local/bin/ mcrcon
chmod +x /usr/local/bin/mcrcon

# ── Minecraft user & directory ─────────────────────────────────────────────
useradd -m -s /bin/bash minecraft || true
mkdir -p "$MC_DIR"

# ── Download latest PaperMC build ─────────────────────────────────────────
cd "$MC_DIR"
PAPER_BUILD=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/$${MC_VERSION}/builds" \
  | jq -r '.builds[-1].build')
curl -sLo server.jar \
  "https://api.papermc.io/v2/projects/paper/versions/$${MC_VERSION}/builds/$${PAPER_BUILD}/downloads/paper-$${MC_VERSION}-$${PAPER_BUILD}.jar"

echo "eula=true" > eula.txt

# ── server.properties ─────────────────────────────────────────────────────
cat > server.properties << PROPEOF
max-players=8
view-distance=8
simulation-distance=6
difficulty=normal
online-mode=true
enable-rcon=true
rcon.password=$${RCON_PASSWORD}
rcon.port=25575
motd=Server is up!
PROPEOF

# ── Download Chunky plugin (pre-generate world) ────────────────────────────
mkdir -p plugins
CHUNKY_URL=$(curl -s "https://api.modrinth.com/v2/project/fALzjamp/version?loaders=%5B%22paper%22%5D" \
  | jq -r '.[0].files[0].url' || echo "")
if [ -n "$CHUNKY_URL" ] && [ "$CHUNKY_URL" != "null" ]; then
  curl -sLo plugins/Chunky.jar "$CHUNKY_URL"
fi

chown -R minecraft:minecraft "$MC_DIR"

# ── systemd service ────────────────────────────────────────────────────────
cat > /etc/systemd/system/minecraft.service << SVCEOF
[Unit]
Description=Minecraft Paper Server
After=network.target

[Service]
User=minecraft
WorkingDirectory=$${MC_DIR}
ExecStart=/usr/bin/java -Xmx12G -Xms4G \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:MaxGCPauseMillis=200 \
  -jar server.jar nogui
ExecStop=/usr/local/bin/mcrcon -H localhost -P 25575 -p $${RCON_PASSWORD} stop
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable minecraft
systemctl start minecraft

# ── Auto-stop: 0 players for 15 min → stop this EC2 ──────────────────────
cat > /usr/local/bin/mc-autostop.sh << 'STOPEOF'
#!/bin/bash
RCON_PASS="__RCON_PASSWORD__"
AWS_REGION_VAL="__AWS_REGION__"
COUNTER_FILE=/tmp/mc_empty_count

# Wait until minecraft service is running before checking
if ! systemctl is-active --quiet minecraft; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

RESPONSE=$(mcrcon -H localhost -P 25575 -p "$RCON_PASS" "list" 2>/dev/null || echo "error")

if echo "$RESPONSE" | grep -q "There are 0"; then
  COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
  COUNT=$((COUNT + 1))
  echo $COUNT > "$COUNTER_FILE"
  echo "$(date): No players ($${COUNT}/3 checks before shutdown)"

  if [ "$COUNT" -ge 3 ]; then
    echo "$(date): 15 min empty - stopping instance"
    rm -f "$COUNTER_FILE"
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    /usr/local/bin/aws ec2 stop-instances \
      --region "$AWS_REGION_VAL" \
      --instance-ids "$INSTANCE_ID"
  fi
else
  # Players online, reset counter
  rm -f "$COUNTER_FILE"
fi
STOPEOF

sed -i "s/__RCON_PASSWORD__/$${RCON_PASSWORD}/" /usr/local/bin/mc-autostop.sh
sed -i "s/__AWS_REGION__/$${AWS_REGION}/" /usr/local/bin/mc-autostop.sh
chmod +x /usr/local/bin/mc-autostop.sh

# Check every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/mc-autostop.sh >> /var/log/mc-autostop.log 2>&1") | crontab -

# ── S3 Backup: every 6 hours ───────────────────────────────────────────────
cat > /usr/local/bin/mc-backup.sh << BAKEOF
#!/bin/bash
DATE=\$(date +%Y%m%d-%H%M)
MC_DIR_PATH="$${MC_DIR}"
BUCKET="$${BACKUP_BUCKET}"
REGION="$${AWS_REGION}"

# Pause chunk saving to get clean backup
/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-off" 2>/dev/null || true
/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-all" 2>/dev/null || true
sleep 5

tar -czf /tmp/mc-backup-\$DATE.tar.gz \
  -C "\$MC_DIR_PATH" world world_nether world_the_end 2>/dev/null || \
tar -czf /tmp/mc-backup-\$DATE.tar.gz -C "\$MC_DIR_PATH" world

/usr/local/bin/aws s3 cp /tmp/mc-backup-\$DATE.tar.gz \
  "s3://\$BUCKET/backups/mc-backup-\$DATE.tar.gz" \
  --region "\$REGION"

rm -f /tmp/mc-backup-\$DATE.tar.gz

/usr/local/bin/mcrcon -H localhost -P 25575 -p "$${RCON_PASSWORD}" "save-on" 2>/dev/null || true
echo "\$(date): Backup \$DATE uploaded to s3://\$BUCKET"
BAKEOF
chmod +x /usr/local/bin/mc-backup.sh

(crontab -l 2>/dev/null; echo "0 */6 * * * /usr/local/bin/mc-backup.sh >> /var/log/mc-backup.log 2>&1") | crontab -

echo "Minecraft server setup complete!"
echo "Run after server starts: /chunky radius 3000 && /chunky start"
