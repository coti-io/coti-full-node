#!/bin/bash
# Reset full node when node panics with "Head state missing" or database corruption.
# Preserves nodekey and keystore. Requires full re-sync after running.

set -e

# Choose compose command: prefer "docker compose" (v2 plugin) when available
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- ROOT CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    echo
    echo "Example:"
    echo '  sudo ./reset_coti-full-node.sh'
    exit 1
fi

echo "WARNING: This will delete all node data. The node will need to re-sync from genesis."
echo "Your nodekey and keystore will be preserved."
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY] ]]; then
    echo "Aborted."
    exit 1
fi

# Load .env for docker-compose
if [ -f .env ]; then
    set -a
    source .env
    source installer.env
    set +a
fi

echo "--> Stopping containers..."
$DC down 2>/dev/null || true

echo "--> Removing geth directory (preserving nodekey as it is mapped to the container)..."
rm -rf ./execution/geth/

echo "--> Done. Run ./start_coti-full-node.sh to re-init and re-sync."
