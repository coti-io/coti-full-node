#!/bin/bash
# Reset full node when node panics with "Head state missing" or database corruption.
# Preserves nodekey (host file). Drops chain data (Docker named volume) and requires full re-sync after running.

set -e

# Require Compose v2 (docker compose); legacy docker-compose v1 is not supported.
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: \`docker compose\` (Compose v2 plugin) is required."
    echo "Install docker-compose-v2 (Ubuntu docker.io) or docker-compose-plugin (Docker CE)."
    exit 1
fi
DC="docker compose"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=scripts/source-env.sh
. "$SCRIPT_DIR/scripts/source-env.sh"
source_coti_env "$SCRIPT_DIR"

# --- ROOT CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    echo
    echo "Example:"
    echo '  sudo ./reset_coti-full-node.sh'
    exit 1
fi

echo "WARNING: This will delete all chain data (Docker volume). The node will need to re-sync from genesis."
echo "Your ./nodekey file on this host is preserved."
read -p "Continue? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY] ]]; then
    echo "Aborted."
    exit 1
fi

ALL_PROFILE_ARGS=(--profile frpc --profile proxy-nginx --profile setup)
echo "--> Stopping containers and removing chain volume (nodekey on host is preserved)..."
$DC "${ALL_PROFILE_ARGS[@]}" down -v 2>/dev/null || true

echo "--> Done. Run ./start_coti-full-node.sh to re-init and re-sync."
