#!/bin/bash

# Choose compose command: prefer "docker compose" (v2 plugin) when available
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

# Load .env if present (needed for docker-compose variable substitution)
if [ -f .env ]; then
    set -a
    source .env
    source installer.env
    set +a
fi

# Enable every compose profile so `down` stops optional stacks too (frpc, nginx, nginx-init/setup).
ALL_PROFILE_ARGS=(--profile frpc --profile proxy-nginx --profile setup)
$DC "${ALL_PROFILE_ARGS[@]}" down