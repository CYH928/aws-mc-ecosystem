# Project Overview

## What This Is

A cost-optimized Minecraft Java Edition server on AWS, designed for **8 concurrent players**.

The key design goal: **pay only when players are online**. The Minecraft server (expensive) automatically starts when a player tries to connect, and shuts itself down after 3 minutes of inactivity.

---

## Architecture

```
Players
  │
  │  connect to DuckDNS domain (free dynamic DNS)
  ▼
┌─────────────────────────────┐
│  Watcher Machine            │  t4g.nano (~$3.4/mo) — ALWAYS ON
│  - mc-proxy (Python proxy)  │
│  - MC Web Control Panel     │  port 8080, always accessible
│  - DuckDNS IP updater       │
│  - IAM: can start MC EC2    │
└──────────────┬──────────────┘
               │  player connects → boots MC EC2 via AWS API
               │  then proxies all TCP traffic to MC server
               ▼
┌─────────────────────────────┐
│  Minecraft Server           │  t3.xlarge — STARTS/STOPS ON DEMAND
│  - Pterodactyl Panel + Wings│  manages PaperMC in Docker containers
│  - Docker (MC processes)    │
│  - fix-panel-ip.service     │  auto-fix IP on every boot
│  - Auto-stop script (cron)  │
│  - S3 backup script (cron)  │
│  - IAM: can stop itself     │
│  - IAM: can write S3        │
└──────────────┬──────────────┘
               │  world data backup every 1 hour + on boot/shutdown
               ▼
┌─────────────────────────────┐
│  S3 Bucket                  │  backups auto-deleted after 30 days
└─────────────────────────────┘

CloudWatch  →  billing alarm email when monthly cost > $50
```

---

## Two-Machine Design: Why?

**Problem:** When the MC server EC2 is stopped, nothing is listening on port 25565. Players cannot connect, and there is no trigger to start it.

**Solution:** A tiny always-on Watcher machine runs `mc-proxy`, a custom Python TCP proxy (`/opt/mc-proxy/proxy.py`) that:
1. Listens on port 25565 at all times
2. When a player connects, runs a shell script that boots the MC EC2 via AWS API
3. Shows the player a "Server is starting..." message while waiting
4. Once MC server is online, transparently proxies all game traffic through

**Why not Elastic IP?**
- Elastic IP costs ~$3.6/mo when the instance is stopped (which is most of the time)
- Instead, the Watcher uses DuckDNS (free dynamic DNS) — its IP never changes because it never stops

**Why not Lambda/serverless?**
- Minecraft uses raw TCP, not HTTP. Lambda cannot listen on arbitrary TCP ports.
- A small always-on EC2 is the only practical solution for TCP-based wake-on-connect.

---

## Fixed Private IP

The MC server is assigned a fixed private IP (`cidrhost(subnet_cidr, 100)` in Terraform). This is critical because:
- `mc-proxy` needs a stable address to proxy traffic to
- Without a fixed private IP, the address would change every time the EC2 stops and restarts
- No Elastic IP is needed for this — private IPs within a VPC can be fixed at no cost

---

## Cost Estimate

| Component | Cost |
|---|---|
| t4g.nano Watcher (730 hrs/mo) | ~$3.4/mo |
| t3.xlarge MC server (varies) | ~$0.166/hr when running |
| 30 GB gp3 EBS disk | ~$2.4/mo |
| S3 backups (~5 GB) | ~$0.12/mo |
| CloudWatch (free tier) | $0 |
| **If playing 4 hrs/day** | **~$26/mo total** |
| **If playing 1 hr/day** | **~$11/mo total** |

---

## Technology Choices

| Component | Choice | Reason |
|---|---|---|
| Game server | PaperMC (managed by Pterodactyl in Docker) | Better performance than vanilla, plugin support |
| Wake-on-connect | Custom Python TCP proxy (mc-proxy) | Lightweight, no external dependencies, full control over EC2 start/proxy logic |
| Dynamic DNS | DuckDNS | Free, reliable, simple API |
| World pre-generation | Chunky plugin | Eliminates chunk-gen lag when players explore |
| Admin panel | Pterodactyl | Industry standard for game server management |
| Web control panel | MC Web Control Panel (Python) | Always-on web UI on Watcher for Start/Stop EC2, status, players, Pterodactyl link |
| IP auto-fix | fix-panel-ip.service | Updates Panel APP_URL, Node FQDN, Wings CORS on every MC server boot |
| Infrastructure | Terraform | Reproducible, AI-maintainable, version-controllable |
| Region | ap-east-1 (HK) | Lowest latency for Hong Kong players |
