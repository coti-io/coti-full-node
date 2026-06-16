#!/bin/bash
# Cleanup script for testing install_coti-full-node.sh from scratch.
# Can be run from anywhere; targets the coti-full-node directory (where this script lives).

set -e

# Require Compose v2 (docker compose); legacy docker-compose v1 is not supported.
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: \`docker compose\` (Compose v2 plugin) is required."
    echo "Install docker-compose-v2 (Ubuntu docker.io) or docker-compose-plugin (Docker CE)."
    exit 1
fi
DC="docker compose"

# --- ROOT CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    echo
    echo "Example:"
    echo '  sudo ./cleanup_coti-full-node.sh'
    exit 1
fi

# Use script's directory (coti-full-node), NOT current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$SCRIPT_DIR"

# shellcheck source=scripts/source-env.sh
. "$DIR/scripts/source-env.sh"
source_coti_env "$DIR"

DOMAIN=""
DOMAIN="${FULLNODE_FQDN:-}"

echo "Cleaning up for fresh install test..."
echo "Directory: $DIR"
echo "Domain (for cert removal): ${DOMAIN:-none}"
echo ""
echo "WARNING: This will remove the entire coti-full-node directory and all data."
echo "Docker containers will be stopped and the directory will be deleted."
echo ""
echo "*** CRITICAL: Your private key (nodekey) will be PERMANENTLY DELETED. ***"
echo "*** This script is for TESTING PURPOSES ONLY. Do not use in production. ***"
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY] ]]; then
    echo "Aborted."
    exit 1
fi

# Stop and remove containers (all profiles) and named volumes (e.g. chain data)
if [ -f "$DIR/docker-compose.yml" ]; then
    echo "--> Stopping Docker containers and project volumes..."
    (cd "$DIR" && $DC --profile frpc --profile proxy-nginx --profile setup down -v 2>/dev/null || true)
fi

# Remove cloned repo
if [ -d "$DIR" ]; then
    echo "--> Removing $DIR..."
    rm -rf "$DIR"
fi

# Remove Let's Encrypt cert if domain specified
if [ -n "$DOMAIN" ]; then
    echo "--> Removing cert for $DOMAIN..."
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
fi

echo ""
echo "Done. Run install_coti-full-node.sh again to test from scratch."
echo "Example (Linux / macOS / Windows WSL on Ubuntu 24.04):"
echo '  curl -sL https://fullnode.<network>.coti.io/install-linux | sudo bash -s -- "0x..." "your.domain"'
echo "On WSL, install from ~/... not /mnt/c/... (Docker + Geth IPC need a Linux filesystem path)."
