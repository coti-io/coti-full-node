#!/bin/bash

# Require Compose v2 (docker compose); legacy docker-compose v1 is not supported.
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: \`docker compose\` (Compose v2 plugin) is required."
    echo "Install docker-compose-v2 (Ubuntu docker.io) or docker-compose-plugin (Docker CE)."
    exit 1
fi
DC="docker compose"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/source-env.sh
. "$SCRIPT_DIR/scripts/source-env.sh"
source_coti_env "$SCRIPT_DIR"

# Enable every compose profile so `down` stops optional stacks too (frpc, nginx, nginx-init/setup).
ALL_PROFILE_ARGS=(--profile frpc --profile proxy-nginx --profile setup)
$DC "${ALL_PROFILE_ARGS[@]}" down