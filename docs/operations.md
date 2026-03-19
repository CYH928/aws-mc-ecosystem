# Operations Guide

Day-to-day tasks for managing the server after deployment.

---

## Checking Server Status

```bash
# SSH into either machine, then:
bash mc_status.sh
```

Shows: EC2 state, player list, TPS, RAM/CPU usage, last backup.

---

## Connecting to Machines via SSH

```bash
# Watcher (always on, always has a public IP)
ssh -i minecraft-key.pem ubuntu@<watcher_public_ip>

# MC Server (only has a public IP when running)
ssh -i minecraft-key.pem ubuntu@<mc_server_public_ip>
```

> Get current IPs: `terraform output` from the terraform/ directory, or from AWS Console → EC2 → Instances.

---

## MC Web Control Panel

The easiest way to manage the MC server. Runs on the Watcher machine, so it is **always accessible** even when the MC server is stopped.

**URL:** `http://it114115.duckdns.org:8080?token=koei2026`

### Features:

- **Start** — boots the MC server EC2 instance
- **Stop** — graceful shutdown: warns players (10s countdown) → save-all → stop MC → stop EC2 (~30 seconds total)
- **Status** — shows whether MC EC2 is running or stopped
- **Players** — lists currently online players
- **Open Pterodactyl Panel** — direct link with the correct current IP (since the IP changes on every boot)

### Authentication:

The `?token=koei2026` query parameter is required. Additionally, port 8080 on the Watcher Security Group is restricted to `admin_cidr`.

### Monitoring:

```bash
# SSH into Watcher
sudo systemctl status mc-web-panel
sudo journalctl -u mc-web-panel -f
```

---

## IP Auto-Fix on Boot

The MC server runs `fix-panel-ip.service` on every boot, which automatically updates:
- Panel `APP_URL` in `/var/www/pterodactyl/.env`
- Node FQDN in the Pterodactyl database
- Wings CORS `allowed_origins` in `/etc/pterodactyl/config.yml`

It then restarts Panel/Wings services and auto-starts all Pterodactyl servers. This means after the MC EC2 boots, Pterodactyl Panel is fully functional with the correct IP — no manual intervention required.

---

## Starting / Stopping the MC Server Manually

The server auto-starts when a player connects and auto-stops after 3 min of inactivity. The **MC Web Control Panel** (above) is the recommended way for manual control. For CLI alternatives:

**Start manually:**
```bash
# From AWS Console: EC2 → Instances → select minecraft-server → Start
# Or from any machine with AWS CLI:
aws ec2 start-instances \
  --region ap-east-1 \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=minecraft-server" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)
```

**Stop manually (emergency):**
```bash
# SSH into MC server, then:
# Stop all Pterodactyl Docker containers first
sudo docker stop $(sudo docker ps -q) 2>/dev/null
sudo /usr/local/bin/aws ec2 stop-instances \
  --region ap-east-1 \
  --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
```

---

## Sending Commands to the Server

Via RCON (from MC server SSH session):
```bash
mcrcon -H localhost -P 25575 -p YOUR_RCON_PASSWORD
```

Useful commands once in the RCON shell:
```
list          # show online players
tps           # show server performance (20 = perfect, <15 = lagging)
say Hello!    # broadcast message to all players
op playername # give operator to a player
kick playername # kick a player
ban playername  # ban a player
save-all      # force save world to disk
stop          # graceful shutdown
```

Exit RCON: `Ctrl+C`

---

## Viewing Server Logs

```bash
# MC server logs (Pterodactyl Docker containers)
sudo docker logs $(sudo docker ps -q) -f --tail 100

# Or use Pterodactyl Panel Console tab (recommended — no SSH needed)

# Auto-stop log
tail -f /var/log/mc-autostop.log

# Backup log
tail -f /var/log/mc-backup.log

# Wings log (Pterodactyl game server daemon)
sudo journalctl -u wings -f

# mc-proxy log (on Watcher)
sudo journalctl -u mc-proxy -f
```

---

## Backups

### Automatic Backups
Backups run every 1 hour automatically, plus on every boot (via `fix-panel-ip.sh`) and before shutdown (via MC Web Control Panel). Files are stored in S3 as:
```
s3://YOUR_BUCKET/backups/mc-backup-YYYYMMDD-HHMM.tar.gz
```
Files older than 30 days are automatically deleted.

### Manual Backup
```bash
# SSH into MC server
sudo bash /usr/local/bin/mc-backup.sh
```

### Restoring from Backup
```bash
# Copy script to MC server (from your local machine)
scp -i minecraft-key.pem scripts/mc_restore.sh ubuntu@<mc_ip>:~

# SSH in and run
ssh -i minecraft-key.pem ubuntu@<mc_ip>
sudo bash mc_restore.sh

# Or restore a specific backup:
sudo bash mc_restore.sh mc-backup-20240101-1200.tar.gz
```

The restore script creates a safety backup of the current world before overwriting it, saved to `/tmp/`.

### Listing Available Backups
```bash
aws s3 ls s3://YOUR_BUCKET/backups/ --region ap-east-1 | sort -r
```

---

## Updating PaperMC

```bash
# Copy script to MC server (from your local machine)
scp -i minecraft-key.pem scripts/mc_update_paper.sh ubuntu@<mc_ip>:~

# SSH in and run
ssh -i minecraft-key.pem ubuntu@<mc_ip>
sudo bash mc_update_paper.sh

# Or specify a version:
sudo bash mc_update_paper.sh 1.21.5
```

The script warns players 30 seconds before restarting.

---

## Adding / Updating Plugins

Use the Pterodactyl Panel GUI (recommended):
1. Go to your server page → **Files** tab
2. Navigate to `plugins/` folder
3. Upload the plugin `.jar` file
4. **Restart** the server from the Console tab

Or via RCON (if plugin supports hot-reload):
```bash
mcrcon -H localhost -P 25575 -p YOUR_RCON_PASSWORD "reload confirm"
```

---

## Adjusting Auto-Stop Timer

Default: shuts down after 3 minutes of 0 players (3 checks × 1 min).

To change to 30 minutes (6 checks):
```bash
# SSH into MC server
sudo nano /usr/local/bin/mc-autostop.sh
# Change: if [ "$COUNT" -ge 3 ]; then
# To:     if [ "$COUNT" -ge 6 ]; then
```

---

## Adjusting Server RAM

Default: 12 GB (on t3.xlarge with 16 GB RAM).

To change:
1. Log into Pterodactyl Panel → Admin area
2. Go to **Servers** → select your server
3. Under **Build Configuration**, change **Memory** (in MB)
4. Save and restart the server from the Console tab

---

## Changing Instance Type

To upgrade/downgrade the MC server (e.g., switch from t3.xlarge to c6a.xlarge):

1. Edit `terraform/variables.tf`: change `mc_instance_type` default
2. Or edit `terraform/terraform.tfvars`: change `mc_instance_type`
3. Run `terraform apply`

Terraform will stop the instance, change its type, and restart it. World data is preserved (it's on the EBS volume, not the instance).

---

## DuckDNS IP Update

The Watcher updates DuckDNS every 5 minutes automatically. If players report they can't connect after the Watcher was briefly unavailable:

```bash
# SSH into Watcher
/opt/duckdns/update.sh
cat /opt/duckdns/duck.log  # should show "OK"
```

---

## Monitoring mc-proxy (Watcher)

```bash
# SSH into Watcher
sudo systemctl status mc-proxy
sudo journalctl -u mc-proxy -f
```

If mc-proxy crashes, it restarts automatically (Restart=always in systemd).

---

## Pterodactyl Panel

The Pterodactyl Panel provides a web UI for managing the Minecraft server. It runs on the MC server machine (port 8080) and is only accessible when the MC server EC2 is running.

**Access:** Use the **"Open Pterodactyl Panel"** button in the MC Web Control Panel — it always has the correct current IP.

> The MC server's public IP changes every time it stops and starts. The `fix-panel-ip.service` on the MC server automatically updates Panel APP_URL, Node FQDN, and Wings CORS on every boot, so the Panel works correctly without manual IP fixes.

```bash
# Check Panel services (on MC server)
sudo systemctl status nginx
sudo systemctl status php8.3-fpm
sudo systemctl status pteroq

# Check Wings (Docker game server daemon)
sudo systemctl status wings
sudo journalctl -u wings -f
```

For detailed setup and administration, see [docs/pterodactyl-admin-guide.md](pterodactyl-admin-guide.md).

---

## Resizing the World Disk

If the 30 GB EBS volume gets full:

1. In AWS Console: EC2 → Volumes → select the MC server volume → Modify Volume → increase size
2. SSH into MC server:
```bash
sudo growpart /dev/xvda 1
sudo resize2fs /dev/xvda1
df -h  # verify new size
```
No restart needed.
