#!/bin/bash
# ============================================================
# Update PaperMC to latest build
# Usage: sudo bash mc_update_paper.sh [minecraft-version]
# Example: sudo bash mc_update_paper.sh 1.21.4
# No argument = use current version in server.properties
# ============================================================
set -euo pipefail

# Find server directory in Pterodactyl volumes dynamically
MC_DIR=$(find /var/lib/pterodactyl/volumes/ -maxdepth 2 -name "server.properties" -printf "%h\n" 2>/dev/null | head -1)
if [ -z "$MC_DIR" ]; then
  echo "ERROR: Could not find Pterodactyl server volume."
  echo "Check /var/lib/pterodactyl/volumes/"
  exit 1
fi
echo "Found server directory: ${MC_DIR}"
RCON_PASS=$(grep "rcon.password" "$MC_DIR/server.properties" | cut -d'=' -f2 | tr -d ' ')

# ── Determine target MC version ────────────────────────────────────────────
if [ -n "${1:-}" ]; then
  MC_VERSION="$1"
else
  # Read from server.properties (set by motd or version file)
  MC_VERSION=$(find "$MC_DIR" -name "paper-*.jar" 2>/dev/null \
    | head -1 \
    | grep -oP '\d+\.\d+\.?\d*' \
    | head -1)

  if [ -z "$MC_VERSION" ]; then
    read -rp "Enter Minecraft version (e.g. 1.21.4): " MC_VERSION
  fi
fi

echo "Target version: ${MC_VERSION}"

# ── Get latest build number ────────────────────────────────────────────────
echo "Checking latest Paper build for ${MC_VERSION}..."
LATEST_BUILD=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds" \
  | jq -r '.builds[-1].build')

if [ -z "$LATEST_BUILD" ] || [ "$LATEST_BUILD" = "null" ]; then
  echo "ERROR: Could not find Paper builds for version ${MC_VERSION}"
  exit 1
fi

# Check current build (skip if already latest)
CURRENT_JAR=$(ls "$MC_DIR"/paper-*.jar 2>/dev/null | head -1 || echo "server.jar")
CURRENT_BUILD=$(echo "$CURRENT_JAR" | grep -oP '(?<=paper-)[0-9]+(?=\.jar)' || echo "unknown")

if [ "$CURRENT_BUILD" = "$LATEST_BUILD" ]; then
  echo "Already on latest build #${LATEST_BUILD}. Nothing to do."
  exit 0
fi

echo "Current build: ${CURRENT_BUILD}"
echo "Latest build : ${LATEST_BUILD}"
read -rp "Update now? [Y/n] " CONFIRM
if [[ "${CONFIRM,,}" = "n" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Download new jar ───────────────────────────────────────────────────────
NEW_JAR="paper-${MC_VERSION}-${LATEST_BUILD}.jar"
echo "Downloading ${NEW_JAR}..."
curl -Lo "/tmp/${NEW_JAR}" \
  "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${LATEST_BUILD}/downloads/${NEW_JAR}"

# ── Graceful stop ──────────────────────────────────────────────────────────
echo "Stopping server gracefully..."
if mcrcon -H localhost -P 25575 -p "$RCON_PASS" "say Server updating to Paper ${MC_VERSION} build ${LATEST_BUILD}. Restarting in 30s..." 2>/dev/null; then
  sleep 30
  mcrcon -H localhost -P 25575 -p "$RCON_PASS" "stop" 2>/dev/null || true
fi
sleep 10
sudo docker stop $(sudo docker ps -q) 2>/dev/null || true
sleep 5

# ── Replace jar ────────────────────────────────────────────────────────────
echo "Replacing server.jar..."
cp "$MC_DIR/server.jar" "$MC_DIR/server.jar.bak"
cp "/tmp/${NEW_JAR}" "$MC_DIR/server.jar"
chown pterodactyl:pterodactyl "$MC_DIR/server.jar" 2>/dev/null || chown 988:988 "$MC_DIR/server.jar"
rm -f "/tmp/${NEW_JAR}"

# ── Start server ───────────────────────────────────────────────────────────
echo "Restarting Wings to start updated server..."
systemctl restart wings

echo ""
echo "======================================================"
echo " PaperMC updated successfully!"
echo " Version: ${MC_VERSION} build #${LATEST_BUILD}"
echo " Old jar backed up: ${MC_DIR}/server.jar.bak"
echo "======================================================"
