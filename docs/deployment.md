# Deployment Guide

Complete step-by-step guide from zero to a running server.

---

## Prerequisites

### 1. AWS Account Setup
- Create an AWS account if you don't have one
- Enable billing alerts: AWS Console → Billing → Billing Preferences → enable "Receive Billing Alerts"
- Create an IAM user or use root credentials for Terraform (IAM user with AdministratorAccess is recommended)
- Set up AWS CLI locally: `aws configure`

### 2. Create EC2 Key Pair
In AWS Console → EC2 → Key Pairs → Create Key Pair:
- Name: `minecraft-key` (or whatever you put in `key_pair_name` variable)
- Type: RSA, .pem format
- Download and save the `.pem` file securely
- On Mac/Linux: `chmod 400 minecraft-key.pem`

### 3. Get DuckDNS Token
1. Go to https://www.duckdns.org
2. Sign in with Google/GitHub
3. Create a subdomain (e.g., `mymc`) → your players connect to `mymc.duckdns.org`
4. Copy your token from the top of the page

### 4. Install Terraform
```bash
# Mac
brew install terraform

# Windows (with chocolatey)
choco install terraform

# Verify
terraform version  # must be >= 1.5
```

---

## Step 1: Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region         = "ap-east-1"
key_pair_name      = "minecraft-key"
duckdns_token      = "your-token-here"
duckdns_subdomain  = "mymc"
admin_cidr         = "your-home-ip/32"   # Find your IP: curl ifconfig.me
backup_bucket_name = "mymc-world-backup-2024"  # Must be globally unique
mc_version         = "1.21.4"
rcon_password      = "use-a-strong-password"
alert_email        = "you@email.com"
billing_threshold_usd = 50
```

> **Finding `admin_cidr`:** Run `curl ifconfig.me` in your terminal and append `/32`.
> Setting `admin_cidr = "0.0.0.0/0"` also works but is less secure (anyone can try to SSH).

---

## Step 2: Deploy Infrastructure

```bash
cd terraform
terraform init      # download AWS provider
terraform plan      # preview what will be created (no changes made)
terraform apply     # create everything (takes ~3 minutes)
```

After `terraform apply` succeeds, you'll see outputs like:
```
player_connect_address = "mymc.duckdns.org"
watcher_public_ip      = "18.x.x.x"
mc_server_private_ip   = "172.31.0.100"
pterodactyl_panel_url  = "http://x.x.x.x:8080"
s3_backup_bucket       = "mymc-world-backup-2024"
```

---

## Step 3: Confirm Billing Alert Email

AWS sends a confirmation email to your `alert_email`. Check your inbox and click **"Confirm subscription"** or you won't receive billing alerts.

---

## Step 4: Wait for Boot Scripts

The `mc_init.sh` user_data script runs on first boot and takes **3–5 minutes** to complete (installs Java, AWS CLI, mcrcon, and sets up cron scripts). It does NOT install PaperMC or create a minecraft.service — those are handled by Pterodactyl.

Check progress:
```bash
ssh -i minecraft-key.pem ubuntu@<mc_server_public_ip>
sudo tail -f /var/log/cloud-init-output.log
# Wait until you see: "Minecraft server setup complete!"
```

> Note: The MC server's public IP is visible in AWS Console (EC2 → Instances) or via `mc_status.sh` from the Watcher.

---

## Step 5: Install Pterodactyl Panel

```bash
# Edit credentials at the top of the script before copying
nano scripts/install_pterodactyl.sh
# Change: PANEL_EMAIL, PANEL_PASSWORD

# Copy to MC server and run
scp -i minecraft-key.pem scripts/install_pterodactyl.sh ubuntu@<mc_server_public_ip>:~
ssh -i minecraft-key.pem ubuntu@<mc_server_public_ip>
sudo bash install_pterodactyl.sh   # ~15 minutes
```

After completion, follow the printed "NEXT STEPS" to connect Wings to the Panel.

---

## Step 5b: Create MC Server in Pterodactyl Panel

After Pterodactyl is installed and Wings is connected:

1. Log into Pterodactyl Panel (Admin area)
2. Create a new Server (Egg: Paper, Java 21, version 1.21.x)
3. Set resources: Memory 12288 MB, Disk 20000 MB, CPU unlimited
4. Wait for automatic installation to finish
5. Accept EULA: Files tab → edit `eula.txt` → set `eula=true` → Save
6. Configure `server.properties` through the Files tab (max-players, RCON, view-distance, etc.)
7. Upload Chunky plugin through the Files tab → `plugins/` folder
8. Start the server

PaperMC download, server.properties, eula.txt, and plugins are all managed through the Pterodactyl Panel GUI — there is no minecraft.service or standalone PaperMC installation.

See [docs/pterodactyl-admin-guide.md](pterodactyl-admin-guide.md) for detailed instructions.

---

## Step 6: Pre-generate World (Important!)

Without pre-generation, multiple players exploring simultaneously causes severe lag (chunk generation is CPU-intensive).

Connect to the server via Minecraft client, then use the Pterodactyl Console or RCON:
```bash
mcrcon -H localhost -P 25575 -p your-rcon-password
```
```
/chunky radius 3000
/chunky start
```

This generates a 6000×6000 block area (3000 radius). Takes ~20–40 minutes. Players can play while it runs in the background.

---

## Step 7: Test Auto-Start

1. Stop the MC server EC2 from AWS Console (to test the wake mechanism)
2. Open Minecraft → Add Server → `mymc.duckdns.org`
3. You'll see a "Server is hibernating..." message
4. After ~2 minutes, the server will be joinable

---

## Step 8: Tell Players the Address

Players connect to: **`mymc.duckdns.org`** (or whatever your DuckDNS subdomain is)

Port is the default `25565`, no need to specify it.

---

## Destroying Everything

If you want to completely remove all AWS resources:
```bash
terraform destroy
```

This deletes both EC2 instances, security groups, IAM roles, and CloudWatch alarms.

> **Warning:** The S3 bucket has `force_destroy = false`. Terraform will refuse to delete it if it contains backups. Delete the bucket contents manually first, or change to `force_destroy = true` before destroying.

---

## Re-deploying After Changes

If you modify any `.tf` file:
```bash
terraform plan    # always preview first
terraform apply   # apply changes
```

If you modify `user_data` scripts, Terraform will detect the change and offer to **replace** the EC2 instance (destroy + recreate). Both instances now have `lifecycle { ignore_changes = [user_data] }` in `ec2.tf`, so Terraform will not replace them due to user_data changes. Make any init script changes manually via SSH instead.
