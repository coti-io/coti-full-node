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

sudo $DC down
