# Terraform Files Reference

All files live in `terraform/`. Run all commands from that directory.

---

## main.tf

**Purpose:** Provider configuration and shared data sources.

**Key elements:**
- Two AWS provider blocks: primary region + `us_east_1` alias
  - The alias is required because CloudWatch billing metrics only exist in `us-east-1`, even if your server is in Hong Kong
- `data.aws_vpc.default` — uses the account's default VPC to keep things simple (no custom VPC needed)
- `data.aws_subnet.selected` — picks the first available subnet
- `local.mc_private_ip` — uses `cidrhost(subnet_cidr, 100)` to compute a fixed private IP (e.g., if subnet is `172.31.0.0/20`, private IP = `172.31.0.100`)

**Why `cidrhost`?**
We need the MC server to always be reachable at the same internal address. `cidrhost` deterministically picks the 100th host in whatever subnet Terraform selects, so the address is stable across stop/start cycles without paying for an Elastic IP.

---

## variables.tf

**Purpose:** All configurable inputs. Fill these in `terraform.tfvars`.

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region | `ap-east-1` |
| `key_pair_name` | EC2 SSH key pair name (created in AWS Console) | `my-key` |
| `duckdns_token` | Token from duckdns.org account | `abc-123-...` |
| `duckdns_subdomain` | Subdomain prefix only | `mymc` → `mymc.duckdns.org` |
| `admin_cidr` | Your IP for SSH/Panel access | `1.2.3.4/32` |
| `mc_instance_type` | MC server size | `t3.xlarge` |
| `watcher_instance_type` | Watcher size | `t4g.nano` |
| `backup_bucket_name` | S3 bucket name (globally unique) | `mymc-backups-2024` |
| `mc_version` | Minecraft version | `1.21.4` |
| `rcon_password` | RCON password (server admin console) | strong password |
| `alert_email` | Email for billing alerts | `you@email.com` |
| `billing_threshold_usd` | Alert trigger amount | `50` |

**Sensitive variables** (`rcon_password`, `duckdns_token`) are marked `sensitive = true` in Terraform, so they won't appear in plan/apply output.

---

## outputs.tf

**Purpose:** Prints useful information after `terraform apply` completes.

| Output | Description |
|---|---|
| `player_connect_address` | Domain players use to join (e.g., `mymc.duckdns.org`) |
| `watcher_public_ip` | Watcher's raw IP (fallback before DuckDNS propagates) |
| `mc_server_private_ip` | Fixed private IP of MC server |
| `pterodactyl_panel_url` | Admin panel URL (only works when MC server is running) |
| `s3_backup_bucket` | Backup bucket name |

---

## security_groups.tf

**Purpose:** Firewall rules for both machines.

### Watcher Security Group (`mc-watcher-sg`)
- Port 25565 open to everyone — all players connect here
- Port 22 open to `admin_cidr` only (SSH)
- All outbound allowed (needs to reach MC server and AWS APIs)

### MC Server Security Group (`mc-server-sg`)
- Port 25565 open **only from the Watcher SG** — players never connect directly to MC server
- Port 22 open to `admin_cidr` only (SSH)
- Port 8080 open to `admin_cidr` only (Pterodactyl Panel)
- All outbound allowed (needs S3, AWS API, PaperMC downloads)

**Security note:** Players connecting to 25565 only ever reach the Watcher. The MC server's game port is invisible to the public internet.

---

## iam.tf

**Purpose:** Least-privilege IAM roles for both EC2 machines.

### Watcher Role (`mc-watcher-role`)
Permissions:
- `ec2:StartInstances` — wake up the MC server
- `ec2:DescribeInstances` / `ec2:DescribeInstanceStatus` — check if MC server is ready

### MC Server Role (`mc-server-role`)
Permissions:
- `ec2:StopInstances` — stop itself (restricted to instances tagged `Name=minecraft-server`)
- `ec2:DescribeInstances` — read own instance ID
- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject` — backup/restore world data (restricted to the backup bucket only)

Both roles use instance profiles so the EC2 machines get credentials automatically via the metadata service — no access keys needed in any script.

---

## ec2.tf

**Purpose:** Defines both EC2 instances.

### Watcher (`aws_instance.watcher`)
- AMI: Ubuntu 22.04 ARM64 (matches t4g.nano ARM architecture)
- Uses `watcher_init.sh` as user_data (runs on first boot to install the Python TCP proxy `mc-proxy`)
- Never stopped, so its public IP remains stable
- Has `lifecycle { ignore_changes = [user_data] }` to prevent Terraform from replacing an already-deployed instance

### MC Server (`aws_instance.minecraft`)
- AMI: Ubuntu 22.04 x86_64 (standard t3 architecture)
- `private_ip = local.mc_private_ip` — fixes the private IP
- 30 GB gp3 EBS root volume, encrypted
- Uses `mc_init.sh` as user_data (runs on first boot only)
- Has `lifecycle { ignore_changes = [user_data] }` to prevent Terraform from replacing an already-deployed instance

**Important:** `user_data` runs only on the very first boot. If you need to re-run setup, SSH in and run the script manually.

---

## s3.tf

**Purpose:** World backup storage.

- Versioning enabled — protects against accidental overwrites
- Lifecycle rule: backups in `backups/` prefix deleted after 30 days, old versions after 7 days
- All public access blocked

---

## cloudwatch.tf

**Purpose:** Monthly billing alarm.

- Uses the `us_east_1` provider alias (billing metrics only available there)
- Creates an SNS topic → email subscription
- Alarm fires if estimated monthly charges exceed `billing_threshold_usd` (default $50)
- **After `terraform apply`**, AWS sends a confirmation email to `alert_email`. You must click the confirmation link or you won't receive alerts.

---

## terraform.tfvars.example

**Purpose:** Template showing all required variable values.

Copy to `terraform.tfvars` and fill in before running `terraform apply`:
```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` contains secrets — never commit it to git. Add it to `.gitignore`.
