#!/bin/bash

# Verbose tracing only when debugging (avoids noisy logs and leaking env in production).
if [ "${COTI_FULL_NODE_DEBUG:-}" = "1" ]; then
    set -x
    set -v
fi

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

if [ -z "${FULLNODE_EXT_IP:-}" ] && [ ! -f "$SCRIPT_DIR/.env" ]; then
    if ! FULLNODE_EXT_IP=$(curl -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org); then
        echo "ERROR: Could not detect public IP (api.ipify.org). Set FULLNODE_EXT_IP or add .env." >&2
        exit 1
    fi
    if [ -z "$FULLNODE_EXT_IP" ]; then
        echo "ERROR: Public IP lookup returned empty." >&2
        exit 1
    fi
    export FULLNODE_EXT_IP
    export FULLNODE_FQDN=$(dig -x "$FULLNODE_EXT_IP" +short | head -n 1)
fi

if [ "${FRPC_ENABLED:-false}" = "true" ]; then
    FRPC_PROFILE_ARG="--profile frpc"
else
    FRPC_PROFILE_ARG=""
fi

if [ "${NGINX_ENABLED:-false}" = "true" ]; then
    NGINX_PROFILE_ARG="--profile proxy-nginx"
else
    NGINX_PROFILE_ARG=""
fi

echo "Ensuring latest docker image version (${DOCKER_FULL_NODE_IMAGE_VERSION:-1.2.0}) is pulled..."
$DC $NGINX_PROFILE_ARG $FRPC_PROFILE_ARG pull

echo "Building operator status dashboard (local image, quick when cached)..."
$DC $NGINX_PROFILE_ARG $FRPC_PROFILE_ARG build coti-operator-dashboard

echo "Starting COTI full node services..."
$DC $NGINX_PROFILE_ARG $FRPC_PROFILE_ARG up -d

echo "Node started. Checking liveness..."
./liveness_coti-full-node.sh

echo ""
echo "Operator status page (same machine): http://127.0.0.1:8090"
if [ "${NGINX_ENABLED:-false}" = "true" ] && [ -n "${FULLNODE_FQDN:-}" ]; then
    echo "Operator status page (HTTPS, if TLS is configured): https://${FULLNODE_FQDN}/operator/"
fi
if [ "${FRPC_ENABLED:-false}" = "true" ] && [ -n "${FRPC_CUSTOM_DOMAIN:-}" ]; then
    echo "Operator status page (COTI tunnel): https://${FRPC_CUSTOM_DOMAIN}/operator/"
fi
