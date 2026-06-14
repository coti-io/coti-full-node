#!/bin/bash

# Require Compose v2 (docker compose); legacy docker-compose v1 is not supported.
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: \`docker compose\` (Compose v2 plugin) is required."
    echo "Install docker-compose-v2 (Ubuntu docker.io) or docker-compose-plugin (Docker CE)."
    exit 1
fi
DC="docker compose"

# installer.env first (packaging defaults), then .env (this host).
if [ -f installer.env ] || [ -f .env ]; then
    set -a
    # shellcheck source=/dev/null
    [ -f installer.env ] && . ./installer.env
    # shellcheck source=/dev/null
    [ -f .env ] && . ./.env
    DOCKER_FULL_NODE_IMAGE_VERSION="${IMAGE:-${DOCKER_FULL_NODE_IMAGE_VERSION:-1.2.0}}"
    export DOCKER_FULL_NODE_IMAGE_VERSION
    set +a
fi

# Enable every compose profile so `down` stops optional stacks too (frpc, nginx, nginx-init/setup).
ALL_PROFILE_ARGS=(--profile frpc --profile proxy-nginx --profile setup)
$DC "${ALL_PROFILE_ARGS[@]}" down