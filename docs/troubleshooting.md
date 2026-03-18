# Troubleshooting

---

## Players Can't Connect

### "Connection refused" or immediate timeout
**Cause:** mc-proxy on the Watcher is not running.
```bash
# SSH into Watcher
sudo systemctl status mc-proxy
sudo systemctl restart mc-proxy
sudo journalctl -u mc-proxy -n 50
```

### "Server is hibernating" but server never starts
**Cause:** The mc-proxy failed to boot the MC EC2.
```bash
# SSH into Watcher
sudo journalctl -u mc-proxy -f
# Watch for AWS API errors in the Python proxy logs
```

Common causes:
- IAM role permissions issue → check `mc-watcher-role` in AWS IAM Console
- MC server is already starting (not in `stopped` state yet) → wait and retry
- Wrong AWS region → verify `AWS_REGION` in the mc-proxy.service environment variables

### "Can connect to server but can't join" / auth error
**Cause:** `online-mode=true` requires a legitimate Minecraft account. Player must own the game.

### DuckDNS subdomain not resolving
```bash
# SSH into Watcher
cat /opt/duckdns/duck.log  # should say "OK"
/opt/duckdns/update.sh     # force update
nslookup mymc.duckdns.org  # check DNS propagation
```
If DNS doesn't propagate, give it 5 minutes or use the Watcher's raw IP temporarily.

---

## Server Lag / Low TPS

Check TPS first:
```bash
mcrcon -H localhost -P 25575 -p YOUR_RCON_PASSWORD "tps"
# 20.0 = perfect, <15 = noticeable lag, <10 = severe lag
```

### If lag happens when players explore new areas
World pre-generation hasn't been done. Run Chunky:
```
/chunky radius 3000
/chunky start
```

### If lag is constant
Check CPU:
```bash
top  # look for java process CPU usage
```
If consistently >80% CPU, consider upgrading from t3.xlarge to c6a.xlarge (CPU-optimized, more cost-effective for compute-heavy workloads).

### If lag spikes during backups
The backup runs `save-off` before backing up, which is correct. But if the world is very large, the `tar.gz` compression can spike CPU.
Change backup to use lower compression:
```bash
sudo nano /usr/local/bin/mc-backup.sh
# Change: tar -czf  (c = create, z = gzip compress)
# To:     tar -cf   (no compression, faster but larger files)
```

---

## Server Not Auto-Stopping

### Check auto-stop is running
```bash
# Check cron is set
crontab -l | grep autostop

# Check recent runs
tail -20 /var/log/mc-autostop.log
```

### Check RCON connection
```bash
mcrcon -H localhost -P 25575 -p YOUR_RCON_PASSWORD "list"
# If this fails, RCON is not working → auto-stop cannot check player count
```

If RCON fails, check `server.properties`:
```
enable-rcon=true
rcon.password=YOUR_PASSWORD
rcon.port=25575
```
Then restart: `sudo systemctl restart minecraft`

### Counter file stuck
If the server thinks 0 players even when players are online:
```bash
rm -f /tmp/mc_empty_count
```

---

## Backups Not Working

### Check last backup
```bash
tail -20 /var/log/mc-backup.log
```

### Test backup manually
```bash
sudo bash /usr/local/bin/mc-backup.sh
# Watch for S3 upload errors
```

Common causes:
- IAM permissions on `mc-server-role` don't include the bucket
- Bucket name mismatch in `/etc/mc-backup-bucket`
- World folder name different (e.g., custom world name in `server.properties`)

Check world folder name:
```bash
ls /home/minecraft/server/
# Should see: world  world_nether  world_the_end
```
If world is named differently, edit the `tar` command in `/usr/local/bin/mc-backup.sh`.

---

## Pterodactyl Panel Not Loading

### Check if MC server is running
Panel is only accessible when the MC EC2 is running. Start the server first.

### Check Nginx
```bash
sudo systemctl status nginx
sudo nginx -t  # test config
sudo journalctl -u nginx -n 50
```

### Check PHP-FPM
```bash
sudo systemctl status php8.3-fpm
sudo systemctl restart php8.3-fpm
```

### Check Panel URL after server restart
The MC server's public IP changes every time it stops and starts. Get the new URL:
```bash
terraform output pterodactyl_panel_url
# Or from AWS Console: EC2 → Instances → minecraft-server → Public IPv4
```

---

## Terraform Errors

### "Error: bucket already exists"
S3 bucket names are globally unique. Change `backup_bucket_name` in `terraform.tfvars`.

### "Error: InvalidAMIID" or "no AMI found"
The Ubuntu AMI lookup failed for your region. Check that `aws_region` is a valid region that has Ubuntu 22.04 AMIs available.

### "Error: private IP address ... is not available"
The IP computed by `cidrhost(subnet_cidr, 100)` is already in use in your VPC.
Change `100` to a different host number in `main.tf`:
```hcl
mc_private_ip = cidrhost(data.aws_subnet.selected.cidr_block, 150)
```

### "user_data change forces replacement"
Terraform wants to destroy and recreate the MC server because the init script changed.
To prevent world data loss, either:
1. Add `lifecycle { ignore_changes = [user_data] }` to the MC instance in `ec2.tf`
2. Make sure there is an up-to-date S3 backup before allowing the replacement

---

## World Data Recovery

### If MC server was terminated (not stopped)
EBS root volume is deleted on termination by default. Recovery options:
1. Restore from most recent S3 backup via `mc_restore.sh`
2. If you had manual EBS snapshots, restore from snapshot

**Prevention:** Enable EBS snapshot via AWS Backup service, or change `delete_on_termination = false` in `ec2.tf` root_block_device.

### If restore script fails mid-way
```bash
# Your safety backup is at:
ls /tmp/world-before-restore-*.tar.gz

# Manual restore:
sudo systemctl stop minecraft
rm -rf /home/minecraft/server/world*
tar -xzf /tmp/world-before-restore-DATETIME.tar.gz -C /home/minecraft/server/
sudo systemctl start minecraft
```
