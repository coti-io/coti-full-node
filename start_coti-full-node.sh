#!/bin/bash

# Choose compose command: prefer "docker compose" (v2 plugin) when available
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

# Prefer .env from install_coti-full-node.sh when present; otherwise compute at runtime (legacy behavior)
if [ -f .env ]; then
    set -a
    source .env
    source installer.env
    set +a
else
    export FULLNODE_EXT_IP=$(curl -s https://api.ipify.org)
    export FULLNODE_FQDN=$(dig -x $FULLNODE_EXT_IP +short | head -n 1)
fi

if [ "${FRPC_ENABLED:-false}" = "true" ]; then
    FRPC_PROFILE_ARG="--profile frpc"
else
    FRPC_PROFILE_ARG=""
fi

if [ "${NO_NGINX:-false}" = "true" ]; then
    NGINX_PROFILE_ARG=""
else
    NGINX_PROFILE_ARG="--profile proxy-nginx"
fi

echo "Ensuring latest docker image version (${DOCKER_FULL_NODE_IMAGE_VERSION:-1.2.0}) is pulled..."
$DC $NGINX_PROFILE_ARG $FRPC_PROFILE_ARG pull

echo "Starting COTI full node services..."
$DC $NGINX_PROFILE_ARG $FRPC_PROFILE_ARG up -d

echo "Node started. Checking liveness..."
./liveness_coti-full-node.sh
