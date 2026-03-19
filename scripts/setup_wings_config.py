#!/usr/bin/env python3
"""Fetch Wings config from Panel API and write as YAML"""
import urllib.request
import json
import subprocess
import sys
import os

API_KEY = sys.argv[1] if len(sys.argv) > 1 else ""
PANEL_URL = "http://localhost:8080"

def get_public_ip():
    try:
        req = urllib.request.urlopen("http://169.254.169.254/latest/meta-data/public-ipv4", timeout=5)
        return req.read().decode().strip()
    except:
        return "127.0.0.1"

def fetch_config():
    url = f"{PANEL_URL}/api/application/nodes/1/configuration"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json"
    })
    resp = urllib.request.urlopen(req, timeout=10)
    return json.loads(resp.read().decode())

def write_yaml(data, f, indent=0):
    for k, v in data.items():
        prefix = " " * indent
        if isinstance(v, dict):
            f.write(f"{prefix}{k}:\n")
            write_yaml(v, f, indent + 2)
        elif isinstance(v, list):
            f.write(f"{prefix}{k}:\n")
            if not v:
                f.write(f"{prefix}  []\n")
            else:
                for item in v:
                    if isinstance(item, dict):
                        first = True
                        for ik, iv in item.items():
                            if first:
                                f.write(f"{prefix}  - {ik}: {json.dumps(iv)}\n")
                                first = False
                            else:
                                f.write(f"{prefix}    {ik}: {json.dumps(iv)}\n")
                    else:
                        f.write(f"{prefix}  - {json.dumps(item)}\n")
        elif isinstance(v, bool):
            f.write(f"{prefix}{k}: {'true' if v else 'false'}\n")
        elif v is None:
            f.write(f"{prefix}{k}:\n")
        elif isinstance(v, str):
            if any(c in v for c in ":#{}[]|>&*!%@"):
                f.write(f'{prefix}{k}: "{v}"\n')
            else:
                f.write(f"{prefix}{k}: {v}\n")
        else:
            f.write(f"{prefix}{k}: {v}\n")

if __name__ == "__main__":
    print("Fetching Wings config from Panel...")
    config = fetch_config()

    public_ip = get_public_ip()
    print(f"Public IP: {public_ip}")

    config_path = "/etc/pterodactyl/config.yml"
    with open(config_path, "w") as f:
        write_yaml(config, f)
        f.write(f'allowed_origins:\n  - "http://{public_ip}:8080"\n')
        f.write("allow_cors_private_network: true\n")

    print(f"Config written to {config_path}")
    # Show first 10 lines
    with open(config_path) as f:
        for i, line in enumerate(f):
            if i >= 10:
                break
            print(line.rstrip())
