# Scripts Reference

Scripts are split into two locations based on purpose:

| Location | Scripts | Who runs them |
|---|---|---|
| `terraform/scripts/` | `watcher_init.sh`, `mc_init.sh` | Terraform injects as `user_data` — runs automatically on first EC2 boot. Never run manually. |
| `scripts/` | All others | Admin copies to server via `scp` and runs manually via SSH when needed |

**Why split?** `terraform/scripts/` scripts are tightly coupled to Terraform — they use `templatefile()` variable injection and are referenced by `ec2.tf`. The root `scripts/` are standalone operational tools with no Terraform dependency.

---

## watcher_init.sh (Auto — Watcher machine)

**Runs on:** t4g.nano Watcher, on first boot via Terraform `user_data`
**Purpose:** Sets up everything the Watcher needs to proxy connections and wake the MC server

### What it does step by step:

1. **Installs AWS CLI v2** (ARM64 version for t4g)
2. **Sets up DuckDNS** — writes an update script to `/opt/duckdns/update.sh` and runs it via cron every 5 minutes. This keeps the DuckDNS subdomain pointing to the Watcher's current public IP.
3. **Installs Python 3 and boto3** (for the custom TCP proxy)
4. **Writes `/opt/mc-proxy/proxy.py`** — a custom Python TCP proxy that:
   - Listens on port 25565 for incoming player connections
   - Checks EC2 state of the MC server via AWS API (boto3)
   - Starts the MC EC2 if it is in `stopped` state
   - Waits for the MC server to be running and the game port to be reachable
   - Shows the player a "Server is starting..." message while waiting
   - Transparently proxies all TCP traffic to the MC server's fixed private IP once it is online
5. **Creates systemd service** `mc-proxy.service`:
   - Runs `/opt/mc-proxy/proxy.py` as a systemd unit
   - Starts on boot, restarts on crash (`Restart=always`)
   - Passes configuration via environment variables in the systemd unit file:
     - `MC_SERVER_IP` — fixed private IP of the MC server
     - `AWS_REGION` — e.g., `ap-east-1`
     - `MC_INSTANCE_NAME` — tag name used to find the MC EC2

### Template variables (injected by Terraform):
- `${duckdns_token}`, `${duckdns_subdomain}` — DuckDNS credentials
- `${mc_private_ip}` — fixed private IP computed by `cidrhost()`
- `${aws_region}` — e.g., `ap-east-1`
- `${mc_version}` — e.g., `1.21.4`

---

## mc_init.sh (Auto — MC Server machine)

**Runs on:** t3.xlarge MC Server, on first boot via Terraform `user_data`
**Purpose:** Full Minecraft server setup

### What it does step by step:

1. **Installs system packages:** Java 21, AWS CLI v2, jq, curl, unzip, screen
2. **Installs mcrcon** — command-line RCON client used by auto-stop and backup scripts to communicate with the running Minecraft server
3. **Creates `minecraft` Linux user** — server runs under this user (not root)
4. **Downloads latest PaperMC build** — queries the PaperMC API to get the latest build number for the configured MC version, then downloads that exact jar
5. **Writes `eula.txt`** — accepts Minecraft EULA (required to run)
6. **Writes `server.properties`** — key settings:
   - `max-players=8`
   - `view-distance=8`, `simulation-distance=6` (performance-tuned for t3.xlarge)
   - `enable-rcon=true` with the configured password (required for auto-stop and backup scripts)
7. **Downloads Chunky plugin** — placed in `plugins/` directory. After first server start, run `/chunky radius 3000 && /chunky start` to pre-generate 3000-block radius. This eliminates chunk-gen lag when players explore new areas.
8. **Creates systemd service** `minecraft.service`:
   - JVM flags: `-Xmx12G -Xms4G` (leaves ~4 GB for OS on t3.xlarge's 16 GB RAM)
   - G1GC flags for reduced pause times
   - `ExecStop` uses mcrcon to send `stop` command for a clean shutdown
9. **Saves bucket name** to `/etc/mc-backup-bucket` so `mc_restore.sh` can auto-detect it
10. **Writes auto-stop script** `/usr/local/bin/mc-autostop.sh`:
    - Runs via cron every 5 minutes
    - Uses mcrcon to run `list` command and checks for "There are 0" in response
    - Increments a counter file `/tmp/mc_empty_count` each empty check
    - After 3 consecutive empty checks (= 15 minutes), calls AWS API to stop itself
    - Resets counter whenever players are detected
    - Skips check if `minecraft.service` is not active (prevents shutdown during startup)
11. **Writes S3 backup script** `/usr/local/bin/mc-backup.sh`:
    - Runs via cron every 6 hours
    - Sends `save-off` and `save-all` via RCON before backup (ensures consistent world state)
    - `tar.gz` compresses world, world_nether, world_the_end
    - Uploads to `s3://BUCKET/backups/mc-backup-YYYYMMDD-HHMM.tar.gz`
    - Sends `save-on` after backup completes

### Template variables (injected by Terraform):
- `${backup_bucket}`, `${aws_region}`, `${mc_version}`, `${rcon_password}`

---

## install_pterodactyl.sh (Manual — MC Server machine)

**Location:** `scripts/install_pterodactyl.sh`
**Runs on:** t3.xlarge MC Server, manually via SSH after first boot
**Command:**
```bash
scp -i your-key.pem scripts/install_pterodactyl.sh ubuntu@<mc_ip>:~
ssh -i your-key.pem ubuntu@<mc_ip>
sudo bash install_pterodactyl.sh
```
**Purpose:** Installs Pterodactyl Panel (web UI) + Wings (game server daemon)

### What it does:
1. Installs PHP 8.3, Nginx, MariaDB, Redis, Node.js 20, Composer
2. Creates `panel` database and `pterodactyl` DB user with auto-generated password
3. Downloads Pterodactyl Panel from GitHub, runs `composer install`
4. Configures `.env` with: APP_URL (auto-detected from instance metadata), DB credentials, Redis settings, HK timezone
5. Runs `php artisan migrate --seed` to set up database tables
6. Creates an admin user with credentials defined at top of script
7. Configures Nginx on **port 8080** (matching the security group rule)
8. Sets up queue worker systemd service (`pteroq.service`)
9. Installs Docker (required by Wings)
10. Downloads Wings binary, creates `wings.service` systemd unit

### After running this script:
Wings will NOT start until configured with a Panel token. Follow the printed instructions:
1. Log into Panel → Admin → Nodes → Create Node
2. Generate token → copy config
3. Paste into `/etc/pterodactyl/config.yml`
4. `sudo systemctl start wings`

### Important limitation:
Pterodactyl Panel runs on the MC server machine. When the MC server is stopped (no players), the Panel is also inaccessible. This is by design — there is nothing to manage when the server is off. To start the server manually (without a player connecting), use the AWS Console EC2 panel.

---

## mc_restore.sh (Manual — MC Server machine)

**Location:** `scripts/mc_restore.sh`
**Runs on:** t3.xlarge MC Server, manually when you need to restore a world
**Command:**
```bash
scp -i your-key.pem scripts/mc_restore.sh ubuntu@<mc_ip>:~
ssh -i your-key.pem ubuntu@<mc_ip>
sudo bash mc_restore.sh
# or: sudo bash mc_restore.sh mc-backup-20240101-1200.tar.gz
```
**Purpose:** Restore a world from S3 backup

### What it does:
1. Auto-detects bucket name from `/etc/mc-backup-bucket`
2. Without an argument: lists last 20 backups from S3, prompts you to choose one
3. With a filename argument: uses that backup directly
4. Asks for confirmation before proceeding
5. **Stops the Minecraft server** gracefully
6. Creates a safety backup of the current world to `/tmp/world-before-restore-DATETIME.tar.gz` (so you can undo the restore)
7. Deletes current world folders
8. Downloads chosen backup from S3
9. Extracts and sets correct file ownership
10. **Starts the Minecraft server** again

---

## mc_update_paper.sh (Manual — MC Server machine)

**Location:** `scripts/mc_update_paper.sh`
**Runs on:** t3.xlarge MC Server, manually when you want to update PaperMC
**Command:**
```bash
scp -i your-key.pem scripts/mc_update_paper.sh ubuntu@<mc_ip>:~
ssh -i your-key.pem ubuntu@<mc_ip>
sudo bash mc_update_paper.sh
# or: sudo bash mc_update_paper.sh 1.21.5
```
**Purpose:** Update PaperMC to the latest build

### What it does:
1. Determines target MC version (from argument, or auto-detects from existing jar filename)
2. Queries PaperMC API for latest build number
3. Compares with current build — skips if already up to date
4. Warns players via RCON: "Server updating, restarting in 30s"
5. Waits 30 seconds, then sends `stop` via RCON
6. Backs up current `server.jar` to `server.jar.bak`
7. Downloads and installs new jar
8. Restarts the Minecraft service

---

## mc_status.sh (Manual — either machine)

**Location:** `scripts/mc_status.sh`
**Runs on:** Either Watcher or MC Server
**Command:**
```bash
scp -i your-key.pem scripts/mc_status.sh ubuntu@<any_server_ip>:~
ssh -i your-key.pem ubuntu@<any_server_ip>
bash mc_status.sh
```
**Purpose:** One-command overview of everything

### What it shows:
- EC2 state of both instances (running/stopped) with public IPs and start time
- Minecraft service status (running/stopped)
- Live player list (via RCON)
- Current TPS (ticks per second — below 20 = server is struggling)
- RAM and CPU usage
- Disk usage for world data
- Most recent S3 backup filename and timestamp
- mc-proxy service status
