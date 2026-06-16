#!/bin/bash
# Load network-specific defaults from networks/<network>.env
# Usage: load_network_profile <testnet|mainnet> [repo_root]

load_network_profile() {
    local network="${1:?network required (testnet or mainnet)}"
    local repo_root="${2:-}"

    case "$network" in
        testnet|mainnet) ;;
        *)
            printf '%s\n' "ERROR: Unknown network '$network'. Use testnet or mainnet." >&2
            return 1
            ;;
    esac

    if [ -z "$repo_root" ]; then
        if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "${0:-}" ]; then
            repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        else
            repo_root="$(pwd)"
        fi
    fi

    local profile="$repo_root/networks/${network}.env"
    if [ -f "$profile" ]; then
        # shellcheck source=/dev/null
        . "$profile"
        NETWORK="$network"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if curl -fsSL "https://raw.githubusercontent.com/coti-io/coti-full-node/main/networks/${network}.env" -o "$tmp"; then
        # shellcheck source=/dev/null
        . "$tmp"
        rm -f "$tmp"
        NETWORK="$network"
        return 0
    fi
    rm -f "$tmp"

    printf '%s\n' "ERROR: Could not load network profile for '$network' (missing $profile and fetch failed)." >&2
    return 1
}
