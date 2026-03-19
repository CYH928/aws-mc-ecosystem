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
   - Listens on port 25565 for incoming connections
   - Validates Minecraft protocol handshake (10s timeout) — rejects port scanners and garbage data
   - For **status pings** (server list refresh): responds locally with fake MOTD ("Server is sleeping - join to wake up!") and player count 0/8, without touching EC2
   - For **login attempts** (real player joining): checks EC2 state via AWS API, starts MC EC2 if stopped, waits for server ready, replays the handshake packet, then proxies all TCP traffic
   - Logs connection types as `[SCANNER]`, `[STATUS]`, or `[LOGIN]` for monitoring
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
**Purpose:** Installs base tools and sets up cron scripts. Does NOT install PaperMC, create server.properties, or create any minecraft.service — all MC server management is handled by Pterodactyl Panel + Wings (Docker containers).

### What it does step by step:

1. **Installs system packages:** Java 21, AWS CLI v2, jq, curl, unzip
2. **Installs mcrcon** — command-line RCON client used by auto-stop and backup scripts to communicate with the running Minecraft server via RCON
3. **Saves bucket name** to `/etc/mc-backup-bucket` so backup/restore scripts can auto-detect it
4. **Writes auto-stop script** `/usr/local/bin/mc-autostop.sh`:
    - Runs via cron every 1 minute
    - Uses mcrcon to run `list` command and checks for "There are 0" in response
    - Increments a counter file `/tmp/mc_empty_count` each empty check
    - After 3 consecutive empty checks (= 3 minutes), calls AWS API to stop itself
    - Resets counter whenever players are detected
    - Skips check if no Pterodactyl Docker containers are running (prevents shutdown during startup)
5. **Writes S3 backup script** `/usr/local/bin/mc-backup.sh`:
    - Runs via cron every 1 hour
    - Dynamically finds world data in Pterodactyl volumes (`/var/lib/pterodactyl/volumes/<uuid>/`)
    - Sends `save-off` and `save-all` via RCON before backup (ensures consistent world state)
    - `tar.gz` compresses world, world_nether, world_the_end
    - Uploads to `s3://BUCKET/backups/mc-backup-YYYYMMDD-HHMM.tar.gz`
    - Sends `save-on` after backup completes
    - Also triggered on boot (by `fix-panel-ip.sh`) and before shutdown (by MC Web Control Panel)

### What is NOT in mc_init.sh (handled by Pterodactyl instead):

- PaperMC download — done through Pterodactyl Panel GUI when creating a server
- `server.properties` — configured through Pterodactyl Panel Files tab
- `eula.txt` — accepted through Pterodactyl Panel Files tab
- Chunky plugin — uploaded through Pterodactyl Panel Files tab
- `minecraft.service` — does not exist; Pterodactyl Wings manages MC processes in Docker containers

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

## mc_web_panel.py (Auto — Watcher machine)

**Location:** `scripts/mc_web_panel.py` (source), deployed to `/opt/mc-web-panel/app.py`
**Runs on:** t4g.nano Watcher, as `mc-web-panel.service` (always running)
**Port:** 8080
**URL:** `http://it114115.duckdns.org:8080?token=koei2026`
**Purpose:** Web-based control panel for managing the MC server without SSH

### What it does:

1. **Start EC2** — boots the MC server EC2 instance via AWS API
2. **Stop EC2** — graceful shutdown sequence: warns players (10 second countdown) → `save-all` → `stop` MC process → run S3 backup → stop EC2 instance (~30 seconds total)
3. **Show status** — displays whether the MC EC2 is running or stopped
4. **Show players** — lists currently online players
5. **Link to Pterodactyl Panel** — provides a direct link with the current public IP (since the IP changes on every boot)

### Authentication:

Access is protected by a `?token=` query parameter. The Watcher Security Group also restricts port 8080 to `admin_cidr` only.

### Why on the Watcher:

The Watcher is always on, so the Web Control Panel is always accessible — even when the MC server is stopped. This is the primary way to start the MC server without needing a player to connect or using the AWS Console.

---

## fix-panel-ip.sh (Auto — MC Server machine)

**Location:** `/opt/fix-panel-ip.sh` on MC server
**Runs on:** t3.xlarge MC Server, as `fix-panel-ip.service` on every boot
**Purpose:** Automatically fix Pterodactyl Panel IP addresses after each EC2 stop/start cycle

### Background:

The MC server has no Elastic IP, so its public IP changes every time the EC2 instance stops and restarts. Pterodactyl Panel, Node FQDN, and Wings CORS settings all contain the public IP, so they break after every restart.

### What it does on every boot:

1. **Detects current public IP** from EC2 instance metadata
2. **Updates Panel APP_URL** in `/var/www/pterodactyl/.env`
3. **Updates Node FQDN** in the Pterodactyl database
4. **Updates Wings CORS** `allowed_origins` in `/etc/pterodactyl/config.yml`
5. **Restarts Panel and Wings services** to apply changes
6. **Runs S3 backup** of the current world data (safety backup on boot)
7. **Auto-starts all Pterodactyl servers** so the MC game server is ready without manual intervention

### Why this matters:

Without this service, an admin would need to SSH into the MC server and manually update three different configuration files every time the server restarts. This was previously documented as a known issue (see known-issues.md #5 and #7).

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
- Pterodactyl Docker container status (running/stopped)
- Live player list (via RCON)
- Current TPS (ticks per second — below 20 = server is struggling)
- RAM and CPU usage
- Disk usage for world data
- Most recent S3 backup filename and timestamp
- mc-proxy service status
