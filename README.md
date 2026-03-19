# Minecraft Java Server on AWS

Cost-optimized Minecraft Java server for 8 players. **Automatically starts when a player connects, shuts down after 3 minutes of inactivity.** You only pay when people are actually playing.

**Estimated cost: ~$11–26/month** depending on how many hours per day the server runs.

---

## How It Works

```
Player connects to mymc.duckdns.org
        │
        ▼
Watcher machine (always on, ~$3.4/mo)
  - Runs Python TCP proxy (mc-proxy) on port 25565
  - Validates Minecraft protocol handshake first
  - Port scanners / bots → rejected (no EC2 start)
  - Server list ping → fake MOTD "sleeping" (no EC2 start)
  - Real player login → boots MC EC2 via AWS API
  - Proxies game traffic once server is up
        │
        ▼
Minecraft server (starts/stops on demand)
  - Shuts itself down after 3 min with 0 players
  - Backs up world to S3 every 1 hour + on boot/shutdown
```

For full architecture details, see [docs/overview.md](docs/overview.md).

---

## Prerequisites

Before you begin, you need:

- [ ] AWS account with billing alerts enabled
- [ ] AWS CLI installed and configured (`aws configure`)
- [ ] Terraform >= 1.5 installed
- [ ] An EC2 Key Pair created in your target AWS region
- [ ] A free DuckDNS account and subdomain at https://www.duckdns.org

---

## Deployment

### Step 1 — Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and fill in all values:

| Variable | What to put |
|---|---|
| `aws_region` | `ap-east-1` for Hong Kong |
| `key_pair_name` | Your EC2 Key Pair name |
| `duckdns_token` | Token from duckdns.org |
| `duckdns_subdomain` | e.g. `mymc` → players connect to `mymc.duckdns.org` |
| `admin_cidr` | Your IP + `/32` (run `curl ifconfig.me` to find it) |
| `backup_bucket_name` | A globally unique S3 name, e.g. `mymc-backup-2024` |
| `mc_version` | e.g. `1.21.4` |
| `rcon_password` | Strong password for server console access |
| `alert_email` | Your email for billing alerts |
| `billing_threshold_usd` | Alert when monthly bill exceeds this amount |

### Step 2 — Deploy

```bash
terraform init
terraform plan    # preview what will be created
terraform apply   # deploy everything (~3 minutes)
```

When complete, Terraform prints your server address:
```
player_connect_address = "mymc.duckdns.org"
```

### Step 3 — Confirm billing alert email

AWS sends a confirmation email to your `alert_email`. **Click the link in that email** or you won't receive billing alerts.

---

## Manual Steps After Deployment

Terraform sets up the infrastructure automatically. The following steps must be done **once manually via SSH**.

### Wait for boot (~3–5 minutes)

The Minecraft server runs a setup script on first boot (installs Java, AWS CLI, mcrcon, and cron scripts). It does NOT install PaperMC or create a minecraft.service — those are handled by Pterodactyl. Wait for it to finish:

```bash
ssh -i your-key.pem ubuntu@<mc_server_public_ip>
sudo tail -f /var/log/cloud-init-output.log
# Wait for: "Minecraft server setup complete!"
```

> Get `mc_server_public_ip` from AWS Console → EC2 → Instances → minecraft-server.

---

### Install Pterodactyl Panel (admin web UI)

Pterodactyl is the web-based GUI for managing the server. It must be installed manually because the setup requires interactive configuration.

```bash
# Open the script locally and set your admin credentials at the top
nano scripts/install_pterodactyl.sh
# Edit: PANEL_EMAIL and PANEL_PASSWORD

# Copy script to MC server and run it
scp -i your-key.pem scripts/install_pterodactyl.sh ubuntu@<mc_server_public_ip>:~
ssh -i your-key.pem ubuntu@<mc_server_public_ip>
sudo bash install_pterodactyl.sh   # ~15 minutes
```

After it finishes, follow the printed instructions to connect Wings to the Panel (create a Node in Panel → generate token → paste into `/etc/pterodactyl/config.yml` → start Wings).

**Panel URL:** `http://<mc_server_public_ip>:8080`
> The Panel is only accessible while the MC server EC2 is running.

### Create MC Server in Pterodactyl Panel

After Wings is connected, create your MC server through the Panel GUI:
1. Admin → Servers → Create New (Egg: Paper, Java 21)
2. Set resources: Memory 12288 MB, Disk 20000 MB
3. Accept EULA in Files tab, configure server.properties
4. Upload Chunky plugin to plugins/ folder
5. Start the server

PaperMC, server.properties, eula.txt, and plugins are all managed through the Pterodactyl Panel GUI.

---

### Pre-generate the world map (strongly recommended)

Without this, multiple players exploring new areas simultaneously causes severe lag.

Connect to the server via RCON:
```bash
ssh -i your-key.pem ubuntu@<mc_server_public_ip>
mcrcon -H localhost -P 25575 -p YOUR_RCON_PASSWORD
```

Then run:
```
/chunky radius 3000
/chunky start
```

This generates a 6000×6000 block area. Takes 20–40 minutes. Players can be online while it runs.

---

### Test auto-start

1. Stop the MC server from AWS Console (EC2 → minecraft-server → Stop)
2. Open Minecraft → Add Server → `mymc.duckdns.org`
3. Server list shows "Server is sleeping - join to wake up!" (this does NOT start the EC2)
4. Click "Join Server" — this triggers the EC2 to start, wait ~2 minutes
5. Server starts automatically and you can join

---

## Day-to-Day Operations

| Task | How |
|---|---|
| **MC Web Control Panel** | `http://it114115.duckdns.org:8080?token=koei2026` — **always online** (runs on Watcher). Start/Stop EC2, show status & players, link to Pterodactyl Panel. |
| Pterodactyl Panel | Click "Open Pterodactyl Panel" in Web Control Panel (IP changes on every boot, the link always has the correct IP). Only accessible when MC server is running. |
| Check server status | `bash mc_status.sh` (copy from `scripts/`) |
| Send server command | `mcrcon -H localhost -P 25575 -p PASSWORD "list"` |
| Manual backup | `sudo bash /usr/local/bin/mc-backup.sh` |
| Restore from backup | `sudo bash mc_restore.sh` (copy from `scripts/`) |
| Update PaperMC | `sudo bash mc_update_paper.sh` (copy from `scripts/`) |
| View live server log | Pterodactyl Console tab, or `sudo docker logs $(sudo docker ps -q) -f` |
| View auto-stop log | `tail -f /var/log/mc-autostop.log` |

All scripts and their full documentation are in [docs/scripts.md](docs/scripts.md).

---

## Updating Infrastructure

To change any AWS resource (instance type, disk size, rules, etc.), edit the relevant `.tf` file and run:

```bash
terraform plan    # always preview first
terraform apply
```

> **Note:** Both EC2 instances now have `lifecycle { ignore_changes = [user_data] }` in `ec2.tf`, so Terraform will not replace them due to user_data changes. Make any init script changes manually via SSH instead.

---

## Destroying Everything

To remove all AWS resources and stop all charges:

```bash
terraform destroy
```

> The S3 backup bucket will **not** be deleted automatically (`force_destroy = false`). Delete the bucket contents manually from AWS Console first, then re-run `terraform destroy`.

---

## Documentation

| File | Contents |
|---|---|
| [docs/overview.md](docs/overview.md) | Architecture, design decisions, cost breakdown |
| [docs/terraform-files.md](docs/terraform-files.md) | Every `.tf` file and variable explained |
| [docs/scripts.md](docs/scripts.md) | Every script explained step by step |
| [docs/deployment.md](docs/deployment.md) | Full deployment walkthrough with screenshots |
| [docs/operations.md](docs/operations.md) | Backups, restores, updates, tuning |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and fixes |

---

## Project Structure

```
aws/
├── README.md
├── docs/
│   ├── overview.md
│   ├── terraform-files.md
│   ├── scripts.md
│   ├── deployment.md
│   ├── operations.md
│   └── troubleshooting.md
├── scripts/                      Manual operational tools (copy to server via scp)
│   ├── install_pterodactyl.sh    Run once after deployment to install admin Panel
│   ├── mc_restore.sh             Restore world from S3 backup
│   ├── mc_update_paper.sh        Update PaperMC to latest build
│   └── mc_status.sh              Check server status at a glance
└── terraform/                    Infrastructure as Code (managed by Terraform)
    ├── main.tf                   Provider, VPC, fixed private IP
    ├── variables.tf              All configurable inputs
    ├── outputs.tf                Server address, Panel URL, etc.
    ├── security_groups.tf        Firewall rules
    ├── iam.tf                    AWS permissions for both machines
    ├── ec2.tf                    Watcher + MC server instances
    ├── s3.tf                     Backup storage
    ├── cloudwatch.tf             Billing alarm
    ├── terraform.tfvars.example  Copy this → terraform.tfvars
    └── scripts/                  Auto-init scripts injected by Terraform (do not run manually)
        ├── watcher_init.sh       Runs on Watcher first boot
        └── mc_init.sh            Runs on MC server first boot
```
