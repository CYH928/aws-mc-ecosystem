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
Listens on 25565. Validates Minecraft protocol handshake before acting.
- Port scanners / garbage → rejected immediately
- Status ping (server list) → responds with fake MOTD, no EC2 start
- Login (real player) → starts EC2 if needed, then proxies traffic
"""
import socket, threading, subprocess, time, sys, os, struct, json

MC_SERVER_IP = os.environ.get("MC_SERVER_IP", "127.0.0.1")
MC_SERVER_PORT = int(os.environ.get("MC_SERVER_PORT", "25565"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "25565"))
AWS_REGION = os.environ.get("AWS_REGION", "ap-east-1")
AWS_CLI = "/usr/local/bin/aws"

starting_lock = threading.Lock()
is_starting = False

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

# ── Minecraft varint helpers ─────────────────────────────────────────────

def read_varint(sock, max_bytes=5):
    """Read a Minecraft protocol varint from a socket."""
    result = 0
    raw = b""
    for i in range(max_bytes):
        byte = sock.recv(1)
        if not byte:
            raise ConnectionError("Connection closed during varint")
        raw += byte
        b = byte[0]
        result |= (b & 0x7F) << (7 * i)
        if not (b & 0x80):
            break
    else:
        raise ValueError("Varint too long")
    return result, raw

def write_varint(value):
    """Encode an integer as a Minecraft protocol varint."""
    buf = b""
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            buf += bytes([b | 0x80])
        else:
            buf += bytes([b])
            break
    return buf

def make_packet(packet_id, payload):
    """Build a length-prefixed Minecraft packet."""
    pid_bytes = write_varint(packet_id)
    data = pid_bytes + payload
    return write_varint(len(data)) + data

# ── Minecraft handshake parser ───────────────────────────────────────────

def parse_varint_from_bytes(data, offset):
    """Parse a varint from a byte buffer at given offset. Returns (value, new_offset)."""
    result = 0
    for i in range(5):
        if offset >= len(data):
            return None, offset
        b = data[offset]; offset += 1
        result |= (b & 0x7F) << (7 * i)
        if not (b & 0x80):
            break
    return result, offset

def parse_handshake(client_sock):
    """Read and parse a Minecraft handshake packet.
    Returns dict with next_state + raw_packet, or None if invalid."""
    client_sock.settimeout(10)
    try:
        packet_length, raw_length = read_varint(client_sock)
        if packet_length < 2 or packet_length > 300:
            return None

        payload = b""
        while len(payload) < packet_length:
            chunk = client_sock.recv(packet_length - len(payload))
            if not chunk:
                return None
            payload += chunk

        raw_packet = raw_length + payload
        offset = 0

        # Packet ID — must be 0x00
        packet_id, offset = parse_varint_from_bytes(payload, offset)
        if packet_id is None or packet_id != 0x00:
            return None

        # Protocol version
        protocol_version, offset = parse_varint_from_bytes(payload, offset)
        if protocol_version is None:
            return None

        # Server address (varint-prefixed string)
        addr_len, offset = parse_varint_from_bytes(payload, offset)
        if addr_len is None or addr_len > 255 or offset + addr_len > len(payload):
            return None
        server_address = payload[offset:offset+addr_len].decode("utf-8", errors="replace")
        offset += addr_len

        # Server port (unsigned short, big-endian)
        if offset + 2 > len(payload):
            return None
        server_port = struct.unpack(">H", payload[offset:offset+2])[0]
        offset += 2

        # Next state: 1=status, 2=login
        next_state, offset = parse_varint_from_bytes(payload, offset)
        if next_state not in (1, 2):
            return None

        return {
            "protocol_version": protocol_version,
            "server_address": server_address,
            "server_port": server_port,
            "next_state": next_state,
            "raw_packet": raw_packet,
        }
    except (ConnectionError, ValueError, OSError):
        return None
    finally:
        client_sock.settimeout(None)

# ── Fake status response for sleeping server ─────────────────────────────

def build_status_response():
    """Build a Minecraft Server List Ping response showing the server is sleeping."""
    status = {
        "version": {"name": "1.21.4", "protocol": 770},
        "players": {"max": 8, "online": 0, "sample": []},
        "description": {"text": "\u00a76Server is sleeping\u00a7r - \u00a7ajoin to wake up!"},
        "enforcesSecureChat": False,
    }
    json_bytes = json.dumps(status, ensure_ascii=False).encode("utf-8")
    payload = write_varint(len(json_bytes)) + json_bytes
    return make_packet(0x00, payload)

def handle_status_ping(client_sock, addr):
    """Handle full Server List Ping sequence without touching EC2."""
    try:
        client_sock.settimeout(5)
        # Read status request packet
        try:
            req_length, _ = read_varint(client_sock)
            if req_length > 0:
                client_sock.recv(req_length)
        except:
            pass

        # Send status response
        client_sock.sendall(build_status_response())

        # Handle optional ping packet (packet id 0x01, 8-byte long payload)
        try:
            client_sock.settimeout(5)
            ping_length, _ = read_varint(client_sock)
            if 1 <= ping_length <= 20:
                ping_data = b""
                while len(ping_data) < ping_length:
                    chunk = client_sock.recv(ping_length - len(ping_data))
                    if not chunk:
                        break
                    ping_data += chunk
                if len(ping_data) >= 9:
                    # Echo back: packet_id(0x01) + same 8-byte payload
                    client_sock.sendall(make_packet(0x01, ping_data[1:]))
        except:
            pass
    finally:
        try: client_sock.close()
        except: pass

# ── AWS helpers ──────────────────────────────────────────────────────────

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

# ── Connection handling ──────────────────────────────────────────────────

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

    # Stage 1: Validate Minecraft handshake
    handshake = parse_handshake(client_sock)

    if handshake is None:
        log(f"[SCANNER] {addr[0]} - invalid handshake, closing")
        try: client_sock.close()
        except: pass
        return

    if handshake["next_state"] == 1:
        # Status ping (server list refresh) — respond locally, do NOT start EC2
        log(f"[STATUS] {addr[0]} - server list ping (proto={handshake['protocol_version']})")
        handle_status_ping(client_sock, addr)
        return

    # Stage 2: Login attempt — real player wants to join
    log(f"[LOGIN] {addr[0]} - login attempt (proto={handshake['protocol_version']}, addr={handshake['server_address']})")

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

    # Stage 3: Proxy to real MC server, replaying the handshake first
    try:
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.settimeout(30)
        server_sock.connect((MC_SERVER_IP, MC_SERVER_PORT))
        server_sock.settimeout(None)
    except Exception as e:
        log(f"Cannot connect to MC: {e}")
        client_sock.close()
        return

    # Forward the original handshake packet that was consumed during validation
    server_sock.sendall(handshake["raw_packet"])

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
