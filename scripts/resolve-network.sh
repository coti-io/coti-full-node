#!/bin/bash
# Resolve NETWORK from CLI flags; auto-detect only for piped curl installs.
# Usage: resolve_network <installer_script_path> "$@"

resolve_network() {
    local installer_script="${1:?installer script path required}"
    shift

    local arg fqdn pk_seen=""
    local piped_install=false

    NETWORK=""

    # Piped: curl … | bash -s -- …  (script is stdin, not a file on disk)
    if [ ! -f "$installer_script" ] || [ "$installer_script" = "bash" ] || [ "$installer_script" = "-" ]; then
        piped_install=true
    fi

    for arg in "$@"; do
        case "$arg" in
            --testnet) NETWORK=testnet; NETWORK_SOURCE="--testnet" ;;
            --mainnet) NETWORK=mainnet; NETWORK_SOURCE="--mainnet" ;;
        esac
    done

    if [ -n "${NETWORK:-}" ]; then
        return 0
    fi

    if [ "$piped_install" != "true" ]; then
        printf '%s\n' "ERROR: Network is required when running this script locally. Use --testnet or --mainnet." >&2
        return 1
    fi

    case "${FULLNODE_INSTALLER_URL:-}" in
        *fullnode.mainnet*|*mainnet.coti.io*)
            NETWORK=mainnet
            NETWORK_SOURCE="FULLNODE_INSTALLER_URL"
            return 0
            ;;
        *fullnode.testnet*|*testnet.coti.io*)
            NETWORK=testnet
            NETWORK_SOURCE="FULLNODE_INSTALLER_URL"
            return 0
            ;;
    esac

    fqdn=""
    for arg in "$@"; do
        case "$arg" in
            --*) ;;
            *)
                if [ -z "$pk_seen" ]; then
                    pk_seen=1
                elif [ -z "$fqdn" ]; then
                    fqdn="$arg"
                    break
                fi
                ;;
        esac
    done

    case "$fqdn" in
        *fullnode.mainnet*|*.mainnet.*)
            NETWORK=mainnet
            NETWORK_SOURCE="FQDN"
            ;;
        *fullnode.testnet*|*.testnet.*)
            NETWORK=testnet
            NETWORK_SOURCE="FQDN"
            ;;
    esac

    if [ -z "${NETWORK:-}" ]; then
        printf '%s\n' "ERROR: Could not detect network from FQDN. Use a testnet/mainnet hostname or pass --testnet / --mainnet." >&2
        return 1
    fi

    return 0
}
