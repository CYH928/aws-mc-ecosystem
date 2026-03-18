# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Cost-optimized Minecraft Java Edition server on AWS for 8 players. Two-machine architecture: an always-on t4g.nano Watcher runs a custom Python TCP proxy (mc-proxy) to wake a t3.xlarge MC server on demand, and the MC server auto-stops after 15 minutes of inactivity. All infrastructure managed by Terraform.

## Commands

```bash
cd terraform
terraform init          # first time / after provider changes
terraform plan          # preview changes
terraform apply         # deploy
terraform destroy       # tear down all resources
terraform output        # show server addresses and URLs
```

Manual scripts are in `scripts/` and must be copied to the server via `scp` before running.

## Architecture

**Two EC2 machines with distinct roles:**

- **Watcher** (`t4g.nano`, ARM64, always on): runs a custom Python TCP proxy (`mc-proxy`) at `/opt/mc-proxy/proxy.py` on port 25565. When a player connects, it checks EC2 state, starts the MC EC2 if stopped via AWS API, waits for boot, then proxies TCP traffic to the MC server's fixed private IP. Runs as `mc-proxy.service` with environment variables (MC_SERVER_IP, AWS_REGION, etc.) configured in the systemd unit. Also runs DuckDNS updater on cron.

- **MC Server** (`t3.xlarge`, x86_64, on-demand): runs PaperMC + Pterodactyl Panel. Has two cron jobs: auto-stop (checks player count via RCON every 5 min, stops EC2 after 3 consecutive empty checks) and S3 backup (every 6 hours).

**Key design decisions:**
- MC server uses a fixed private IP via `cidrhost(subnet_cidr, 100)` so the Watcher always knows where to proxy, without needing an Elastic IP.
- CloudWatch billing alarm resources use `provider = aws.us_east_1` alias because billing metrics only exist in us-east-1.
- `terraform/scripts/` use `templatefile()` variable injection — they are NOT standalone shell scripts. Root `scripts/` are standalone.
- `terraform.tfvars` contains secrets (RCON password, DuckDNS token) — never commit it.

## File Layout

- `terraform/` — all `.tf` files and auto-init scripts (`scripts/watcher_init.sh`, `scripts/mc_init.sh`) injected via `user_data`
- `scripts/` — manual operational scripts (Pterodactyl installer, backup restore, PaperMC updater, status check), copied to servers via `scp`
- `docs/` — detailed documentation for each component; `overview.md` explains architecture decisions

## Important Caveats

- Changing `user_data` in `ec2.tf` causes Terraform to **replace** (destroy+recreate) the EC2 instance, which deletes world data. Add `lifecycle { ignore_changes = [user_data] }` if modifying init scripts after deployment.
- The S3 bucket has `force_destroy = false` — must empty bucket before `terraform destroy` will succeed.
- Watcher AMI is ARM64 (for t4g), MC server AMI is x86_64 (for t3) — don't mix them up.
- All user-facing documentation and conversation should be in **Traditional Chinese (Hong Kong)**.
