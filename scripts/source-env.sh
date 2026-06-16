#!/bin/bash
# Source .env, network profile (chain defaults), then .env again so host values win.
# Usage: source scripts/source-env.sh [repo_root]

_source_coti_repo_root() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    if [ -n "${BASH_SOURCE[1]:-}" ]; then
        cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd
        return 0
    fi
    pwd
}

source_coti_env() {
    local repo_root
    repo_root="$(_source_coti_repo_root "${1:-}")"

    set -a
    : "${NETWORK:=testnet}"
    # shellcheck source=/dev/null
    [ -f "$repo_root/.env" ] && . "$repo_root/.env"

    if [ -f "$repo_root/scripts/load-network.sh" ]; then
        # shellcheck source=scripts/load-network.sh
        . "$repo_root/scripts/load-network.sh"
        load_network_profile "${NETWORK:-testnet}" "$repo_root"
    fi

    # Host .env overrides network profile defaults (FRPS, flags, etc.).
    # shellcheck source=/dev/null
    [ -f "$repo_root/.env" ] && . "$repo_root/.env"

    DOCKER_FULL_NODE_IMAGE_VERSION="${IMAGE:-${DOCKER_FULL_NODE_IMAGE_VERSION:-1.2.0}}"
    export DOCKER_FULL_NODE_IMAGE_VERSION
    export NETWORK
    export COTI_SODA_SEQADDR COTI_SODA_EXEC1ADDR COTI_SODA_EXEC2ADDR COTI_NETWORK_ID COTI_BOOTNODES
    set +a
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    source_coti_env "${1:-}"
fi
