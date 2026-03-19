#!/usr/bin/env python3
"""Lightweight MC Server Control Panel - runs on Watcher machine"""
import http.server
import json
import subprocess
import socket
import urllib.parse
import os
import re
import time

AWS_REGION = os.environ.get("AWS_REGION", "ap-east-1")
MC_SERVER_IP = os.environ.get("MC_SERVER_IP", "172.31.16.100")
AWS_CLI = "/usr/local/bin/aws"
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "koei2026")
RCON_PASS = os.environ.get("RCON_PASS", "")
SERVER_NAME = os.environ.get("SERVER_NAME", "Survival World")
CONNECT_ADDRESS = os.environ.get("CONNECT_ADDRESS", "it114115.duckdns.org")

HTML_PAGE = r'''<!DOCTYPE html>
<html lang="zh-HK">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MC Server Control</title>
<script src="https://cdn.tailwindcss.com"></script>
<script>
tailwind.config = {
  theme: {
    extend: {
      colors: {
        dark: { 900: '#0f172a', 800: '#1e293b', 700: '#334155', 600: '#475569' }
      }
    }
  }
}
</script>
<style>
@keyframes pulse-dot { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
.pulse-dot { animation: pulse-dot 2s ease-in-out infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
.spin { animation: spin 1s linear infinite; }
</style>
</head>
<body class="bg-dark-900 min-h-screen flex items-center justify-center p-4">
<div class="w-full max-w-md">
  <!-- Header -->
  <div class="text-center mb-6">
    <div class="inline-flex items-center gap-2 mb-2">
      <svg class="w-8 h-8 text-emerald-400" fill="currentColor" viewBox="0 0 24 24"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
      <h1 class="text-2xl font-bold text-white">MC Server Control</h1>
    </div>
    <p class="text-slate-500 text-sm" id="serverName">Loading...</p>
  </div>

  <!-- Status Card -->
  <div class="bg-dark-800 rounded-2xl border border-slate-700/50 overflow-hidden shadow-2xl">
    <!-- Status Header -->
    <div class="p-6 border-b border-slate-700/50">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class="relative">
            <div class="w-3 h-3 rounded-full" id="statusDot"></div>
            <div class="absolute inset-0 w-3 h-3 rounded-full pulse-dot" id="statusDotPulse"></div>
          </div>
          <div>
            <div class="text-xs text-slate-500 uppercase tracking-wider">Status</div>
            <div class="text-lg font-semibold" id="statusText">Loading...</div>
          </div>
        </div>
        <div id="playerBadge" class="hidden">
          <div class="bg-emerald-500/10 border border-emerald-500/20 rounded-full px-3 py-1">
            <span class="text-emerald-400 text-sm font-medium" id="playerCount"></span>
          </div>
        </div>
      </div>
    </div>

    <!-- Info Grid -->
    <div class="p-6 space-y-3" id="infoGrid">
    </div>

    <!-- Warning -->
    <div id="warning" class="hidden px-6 pb-4">
      <div class="flex items-center gap-2 text-amber-400 text-xs bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
        <svg class="w-4 h-4 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 6a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 6zm0 9a1 1 0 100-2 1 1 0 000 2z" clip-rule="evenodd"/></svg>
        <span id="warningText"></span>
      </div>
    </div>

    <!-- Actions -->
    <div class="p-6 pt-2 space-y-3">
      <div class="grid grid-cols-2 gap-3">
        <button id="startBtn" onclick="doAction('start')" disabled
          class="relative flex items-center justify-center gap-2 px-4 py-3 bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 disabled:text-slate-500 text-white font-semibold rounded-xl transition-all duration-200 disabled:cursor-not-allowed">
          <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M6.3 2.841A1.5 1.5 0 004 4.11V15.89a1.5 1.5 0 002.3 1.269l9.344-5.89a1.5 1.5 0 000-2.538L6.3 2.84z"/></svg>
          Start
        </button>
        <button id="stopBtn" onclick="doAction('stop')" disabled
          class="relative flex items-center justify-center gap-2 px-4 py-3 bg-red-600 hover:bg-red-500 disabled:bg-slate-700 disabled:text-slate-500 text-white font-semibold rounded-xl transition-all duration-200 disabled:cursor-not-allowed">
          <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path d="M5.25 3A2.25 2.25 0 003 5.25v9.5A2.25 2.25 0 005.25 17h9.5A2.25 2.25 0 0017 14.75v-9.5A2.25 2.25 0 0014.75 3h-9.5z"/></svg>
          Stop
        </button>
      </div>

      <a id="panelLink" href="#" target="_blank"
        class="flex items-center justify-center gap-2 px-4 py-3 bg-violet-600 hover:bg-violet-500 text-white font-semibold rounded-xl transition-all duration-200 pointer-events-none opacity-40">
        <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M4.25 5.5a.75.75 0 00-.75.75v8.5c0 .414.336.75.75.75h8.5a.75.75 0 00.75-.75v-4a.75.75 0 011.5 0v4A2.25 2.25 0 0112.75 17h-8.5A2.25 2.25 0 012 14.75v-8.5A2.25 2.25 0 014.25 4h5a.75.75 0 010 1.5h-5zm7.25-.75a.75.75 0 01.75-.75h3.5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-1.69l-5.22 5.22a.75.75 0 01-1.06-1.06l5.22-5.22h-1.69a.75.75 0 01-.75-.75z" clip-rule="evenodd"/></svg>
        Open Pterodactyl Panel
      </a>
    </div>

    <!-- Message -->
    <div id="msg" class="hidden px-6 pb-6">
      <div class="rounded-xl px-4 py-3 text-sm font-medium text-center" id="msgInner"></div>
    </div>
  </div>

  <!-- Footer -->
  <p class="text-center text-slate-600 text-xs mt-4">Watcher Control Panel</p>
</div>

<script>
var TOKEN = new URLSearchParams(window.location.search).get('token') || '';
var CONNECT = '';

function api(path, method) {
  return fetch('/api/' + path + '?token=' + TOKEN, {method: method || 'GET'}).then(function(r) { return r.json(); });
}

function refresh() {
  api('status').then(function(d) {
    // Server name and connect address
    document.getElementById('serverName').textContent = d.server_name || 'Minecraft Server';
    CONNECT = d.connect_address || CONNECT;

    // Status
    var statusText = document.getElementById('statusText');
    var statusDot = document.getElementById('statusDot');
    var statusDotPulse = document.getElementById('statusDotPulse');
    var state = d.state || 'unknown';
    statusText.textContent = state.charAt(0).toUpperCase() + state.slice(1);

    var colors = {
      running: ['bg-emerald-400', 'bg-emerald-400', 'text-emerald-400'],
      stopped: ['bg-red-400', 'bg-red-400', 'text-red-400'],
      stopping: ['bg-amber-400', 'bg-amber-400', 'text-amber-400'],
      pending: ['bg-amber-400', 'bg-amber-400', 'text-amber-400'],
      unknown: ['bg-slate-400', 'bg-slate-400', 'text-slate-400']
    };
    var c = colors[state] || colors.unknown;
    statusDot.className = 'w-3 h-3 rounded-full ' + c[0];
    statusDotPulse.className = 'absolute inset-0 w-3 h-3 rounded-full pulse-dot ' + c[1];
    statusText.className = 'text-lg font-semibold ' + c[2];

    // Players
    var playerBadge = document.getElementById('playerBadge');
    var hasPlayers = d.player_count > 0;
    if (d.players) {
      playerBadge.className = 'block';
      document.getElementById('playerCount').textContent = d.players + ' players';
    } else {
      playerBadge.className = 'hidden';
    }

    // Buttons
    document.getElementById('startBtn').disabled = state === 'running' || state === 'pending';
    var stopBtn = document.getElementById('stopBtn');
    stopBtn.disabled = state !== 'running' || hasPlayers;
    stopBtn.title = hasPlayers ? 'Cannot stop while players are online' : '';

    // Warning
    var warning = document.getElementById('warning');
    if (hasPlayers) {
      warning.className = 'px-6 pb-4';
      document.getElementById('warningText').textContent = 'Cannot stop server while ' + d.player_count + ' player(s) are online';
    } else {
      warning.className = 'hidden';
    }

    // Panel link
    var pl = document.getElementById('panelLink');
    if (state === 'running' && d.public_ip) {
      pl.href = 'http://' + d.public_ip + ':8080';
      pl.className = 'flex items-center justify-center gap-2 px-4 py-3 bg-violet-600 hover:bg-violet-500 text-white font-semibold rounded-xl transition-all duration-200';
    } else {
      pl.className = 'flex items-center justify-center gap-2 px-4 py-3 bg-violet-600 text-white font-semibold rounded-xl transition-all duration-200 pointer-events-none opacity-40';
    }

    // Info grid
    var info = '';
    info += '<div class="flex items-center justify-between"><span class="text-slate-500 text-sm">Connect</span><span class="text-white text-sm font-mono">' + CONNECT + '</span></div>';
    if (d.public_ip) info += '<div class="flex items-center justify-between"><span class="text-slate-500 text-sm">Public IP</span><span class="text-slate-300 text-sm font-mono">' + d.public_ip + '</span></div>';
    if (d.players) info += '<div class="flex items-center justify-between"><span class="text-slate-500 text-sm">Players</span><span class="text-emerald-400 text-sm font-bold">' + d.players + '</span></div>';
    if (state === 'stopped') info += '<div class="flex items-center justify-between"><span class="text-slate-500 text-sm">Note</span><span class="text-slate-400 text-xs">Connect via Minecraft to auto-start</span></div>';
    document.getElementById('infoGrid').innerHTML = info;
  });
}

function doAction(action) {
  var msg = document.getElementById('msg');
  var msgInner = document.getElementById('msgInner');
  msg.className = 'px-6 pb-6';
  if (action === 'start') {
    msgInner.className = 'rounded-xl px-4 py-3 text-sm font-medium text-center bg-emerald-500/10 border border-emerald-500/20 text-emerald-400';
    msgInner.innerHTML = '<span class="inline-block w-4 h-4 border-2 border-emerald-400 border-t-transparent rounded-full spin mr-2 align-middle"></span>Starting server...';
  } else {
    msgInner.className = 'rounded-xl px-4 py-3 text-sm font-medium text-center bg-red-500/10 border border-red-500/20 text-red-400';
    msgInner.innerHTML = '<span class="inline-block w-4 h-4 border-2 border-red-400 border-t-transparent rounded-full spin mr-2 align-middle"></span>Backing up & shutting down...';
  }
  document.getElementById('startBtn').disabled = true;
  document.getElementById('stopBtn').disabled = true;
  api(action, 'POST').then(function(d) {
    msgInner.textContent = d.message;
    msgInner.className = 'rounded-xl px-4 py-3 text-sm font-medium text-center ' +
      (d.ok ? 'bg-emerald-500/10 border border-emerald-500/20 text-emerald-400' : 'bg-red-500/10 border border-red-500/20 text-red-400');
    setTimeout(refresh, 5000);
    setTimeout(function() { msg.className = 'hidden'; }, 15000);
  });
}

refresh();
setInterval(refresh, 8000);
</script>
</body>
</html>'''


def run_aws(args, timeout=15):
    try:
        r = subprocess.run([AWS_CLI] + args, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def get_mc_info():
    info = run_aws(["ec2", "describe-instances",
        "--region", AWS_REGION,
        "--filters", "Name=tag:Name,Values=minecraft-server",
                     "Name=instance-state-name,Values=running,stopped,stopping,pending",
        "--query", "Reservations[0].Instances[0].{State:State.Name,IP:PublicIpAddress,Id:InstanceId}",
        "--output", "json"])
    try:
        return json.loads(info)
    except Exception:
        return {"State": "unknown", "IP": None, "Id": None}


def get_players():
    """Returns (count, display_string) via Minecraft Server List Ping protocol on port 25565"""
    try:
        import struct
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((MC_SERVER_IP, 25565))

        # Send handshake packet (protocol version -1 = status)
        host_bytes = MC_SERVER_IP.encode('utf-8')
        handshake_data = b'\x00'  # packet id
        handshake_data += b'\xff\xff\xff\x0f'  # protocol version (-1 as varint)
        handshake_data += bytes([len(host_bytes)]) + host_bytes  # server address
        handshake_data += struct.pack('>H', 25565)  # server port
        handshake_data += b'\x01'  # next state (1 = status)
        # Send with length prefix
        s.send(bytes([len(handshake_data)]) + handshake_data)

        # Send status request
        s.send(b'\x01\x00')

        # Read response
        data = s.recv(4096)
        s.close()

        # Parse: skip varint length + packet id, find JSON
        json_start = data.find(b'{')
        json_end = data.rfind(b'}') + 1
        if json_start >= 0 and json_end > json_start:
            status = json.loads(data[json_start:json_end].decode('utf-8', errors='ignore'))
            players = status.get("players", {})
            online = players.get("online", 0)
            maximum = players.get("max", 8)
            return online, str(online) + "/" + str(maximum)
        return 0, "0/8"
    except Exception:
        return 0, None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def check_auth(self):
        q = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(q)
        return params.get("token", [""])[0] == AUTH_TOKEN

    def send_json(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/" or path == "":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        elif path == "/api/status":
            if not self.check_auth():
                return self.send_json({"error": "unauthorized"}, 401)
            info = get_mc_info()
            player_count = 0
            player_display = None
            if info.get("State") == "running":
                player_count, player_display = get_players()
            self.send_json({
                "state": info.get("State", "unknown"),
                "public_ip": info.get("IP"),
                "instance_id": info.get("Id"),
                "players": player_display,
                "player_count": player_count,
                "server_name": SERVER_NAME,
                "connect_address": CONNECT_ADDRESS
            })
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not self.check_auth():
            return self.send_json({"error": "unauthorized"}, 401)
        info = get_mc_info()
        iid = info.get("Id")
        if not iid or iid == "None":
            return self.send_json({"ok": False, "message": "Cannot find MC instance"})

        if path == "/api/start":
            if info.get("State") == "running":
                return self.send_json({"ok": True, "message": "Server is already running"})
            run_aws(["ec2", "start-instances", "--region", AWS_REGION, "--instance-ids", iid])
            self.send_json({"ok": True, "message": "Starting server... wait 2-3 minutes"})
        elif path == "/api/stop":
            if info.get("State") != "running":
                return self.send_json({"ok": True, "message": "Server is not running"})
            # Graceful shutdown: backup -> warn players -> save -> stop MC -> stop EC2
            import threading
            def graceful_stop(instance_id):
                try:
                    # Run backup + graceful stop on MC server via SSH
                    subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                        "ubuntu@" + MC_SERVER_IP,
                        "sudo /usr/local/bin/mc-backup.sh && sleep 2 && "
                        "CONTAINER_IP=$(sudo docker inspect $(sudo docker ps -q | head -1) --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null) && "
                        "mcrcon -H $CONTAINER_IP -P 25575 -p '" + RCON_PASS + "' 'say Server shutting down in 10 seconds...' 2>/dev/null; "
                        "sleep 10; "
                        "mcrcon -H $CONTAINER_IP -P 25575 -p '" + RCON_PASS + "' 'save-all' 2>/dev/null; "
                        "sleep 5; "
                        "mcrcon -H $CONTAINER_IP -P 25575 -p '" + RCON_PASS + "' 'stop' 2>/dev/null; "
                        "sleep 15"],
                        capture_output=True, timeout=180)
                except Exception:
                    pass
                # 4. Stop EC2
                run_aws(["ec2", "stop-instances", "--region", AWS_REGION, "--instance-ids", instance_id])
            threading.Thread(target=graceful_stop, args=(iid,), daemon=True).start()
            self.send_json({"ok": True, "message": "Backing up world then shutting down... ~2 minutes"})
        else:
            self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    print(f"MC Web Panel listening on :8080 | Server: {SERVER_NAME}", flush=True)
    server = http.server.HTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
