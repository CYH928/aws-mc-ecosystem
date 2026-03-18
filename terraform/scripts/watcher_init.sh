#!/bin/bash
set -euo pipefail

DUCKDNS_TOKEN="${duckdns_token}"
DUCKDNS_SUBDOMAIN="${duckdns_subdomain}"
MC_PRIVATE_IP="${mc_private_ip}"
AWS_REGION="${aws_region}"
MC_VERSION="${mc_version}"

# ── System update ──────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl jq unzip python3

# Install AWS CLI v2
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# ── DuckDNS: update IP every 5 minutes ────────────────────────────────────
mkdir -p /opt/duckdns
cat > /opt/duckdns/update.sh << DUCKEOF
#!/bin/bash
curl -s "https://www.duckdns.org/update?domains=$${DUCKDNS_SUBDOMAIN}&token=$${DUCKDNS_TOKEN}&ip=" -o /opt/duckdns/duck.log
DUCKEOF
chmod +x /opt/duckdns/update.sh
/opt/duckdns/update.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/duckdns/update.sh") | crontab -

# ── MC Proxy: TCP proxy with EC2 auto-start ───────────────────────────────
mkdir -p /opt/mc-proxy

cat > /opt/mc-proxy/proxy.py << 'PYEOF'
#!/usr/bin/env python3
"""Minecraft TCP Proxy with EC2 Auto-Start
Listens on 25565. If MC server is stopped, starts it.
Proxies all traffic to the MC server's fixed private IP.
"""
import socket, threading, subprocess, time, sys, os

MC_SERVER_IP = os.environ.get("MC_SERVER_IP", "127.0.0.1")
MC_SERVER_PORT = int(os.environ.get("MC_SERVER_PORT", "25565"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "25565"))
AWS_REGION = os.environ.get("AWS_REGION", "ap-east-1")
AWS_CLI = "/usr/local/bin/aws"

starting_lock = threading.Lock()
is_starting = False

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def run_aws(args, timeout=30):
    try:
        r = subprocess.run([AWS_CLI] + args, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except:
        return ""

def get_mc_state():
    return run_aws(["ec2", "describe-instances",
        "--region", AWS_REGION,
        "--filters", "Name=tag:Name,Values=minecraft-server",
        "--query", "Reservations[0].Instances[0].State.Name",
        "--output", "text"])

def get_mc_instance_id():
    return run_aws(["ec2", "describe-instances",
        "--region", AWS_REGION,
        "--filters", "Name=tag:Name,Values=minecraft-server",
        "--query", "Reservations[0].Instances[0].InstanceId",
        "--output", "text"])

def start_mc_ec2():
    global is_starting
    with starting_lock:
        if is_starting:
            return
        is_starting = True
    try:
        iid = get_mc_instance_id()
        if not iid or iid == "None":
            log("ERROR: Cannot find MC instance")
            return
        log(f"Starting EC2 {iid}...")
        run_aws(["ec2", "start-instances", "--region", AWS_REGION, "--instance-ids", iid])
        run_aws(["ec2", "wait", "instance-running", "--region", AWS_REGION, "--instance-ids", iid], timeout=300)
        log("EC2 running, waiting for MC server process...")
        for _ in range(24):
            time.sleep(5)
            if mc_server_is_up():
                log("MC server is ready!")
                return
        log("MC server did not become ready in time")
    finally:
        with starting_lock:
            is_starting = False

def mc_server_is_up():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((MC_SERVER_IP, MC_SERVER_PORT))
        s.close()
        return True
    except:
        return False

def proxy_data(src, dst):
    try:
        while True:
            data = src.recv(8192)
            if not data:
                break
            dst.sendall(data)
    except:
        pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle_client(client_sock, addr):
    log(f"Connection from {addr[0]}")
    state = get_mc_state()

    if state in ("stopped", "stopping"):
        log(f"MC is {state}, triggering start...")
        threading.Thread(target=start_mc_ec2, daemon=True).start()
        for _ in range(36):
            time.sleep(5)
            if mc_server_is_up():
                break
        else:
            log(f"Timeout waiting for MC, closing {addr[0]}")
            client_sock.close()
            return

    elif state in ("running", "pending"):
        for _ in range(12):
            if mc_server_is_up():
                break
            time.sleep(5)
        else:
            log(f"MC not responding, closing {addr[0]}")
            client_sock.close()
            return
    else:
        log(f"Unknown MC state: {state}")
        client_sock.close()
        return

    try:
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.settimeout(30)
        server_sock.connect((MC_SERVER_IP, MC_SERVER_PORT))
        server_sock.settimeout(None)
    except Exception as e:
        log(f"Cannot connect to MC: {e}")
        client_sock.close()
        return

    log(f"Proxying {addr[0]} <-> MC server")
    t1 = threading.Thread(target=proxy_data, args=(client_sock, server_sock), daemon=True)
    t2 = threading.Thread(target=proxy_data, args=(server_sock, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    log(f"Connection from {addr[0]} closed")

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", LISTEN_PORT))
    server.listen(20)
    log(f"MC Proxy listening on :{LISTEN_PORT} -> {MC_SERVER_IP}:{MC_SERVER_PORT}")
    while True:
        client_sock, addr = server.accept()
        threading.Thread(target=handle_client, args=(client_sock, addr), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF

chmod +x /opt/mc-proxy/proxy.py

# systemd service with environment variables
cat > /etc/systemd/system/mc-proxy.service << SVCEOF
[Unit]
Description=Minecraft TCP Proxy with EC2 Auto-Start
After=network.target

[Service]
Type=simple
Environment=MC_SERVER_IP=$${MC_PRIVATE_IP}
Environment=MC_SERVER_PORT=25565
Environment=LISTEN_PORT=25565
Environment=AWS_REGION=$${AWS_REGION}
ExecStart=/usr/bin/python3 /opt/mc-proxy/proxy.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable mc-proxy
systemctl start mc-proxy

echo "Watcher setup complete. DuckDNS: $${DUCKDNS_SUBDOMAIN}.duckdns.org"
