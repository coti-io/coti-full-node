#!/bin/bash
# Source an installer helper from SCRIPT_DIR/scripts or fetch from INSTALLER_REPO_RAW.

INSTALLER_REPO_RAW="${INSTALLER_REPO_RAW:-https://raw.githubusercontent.com/coti-io/coti-full-node/main}"

# Wizard installer entrypoint on fullnode.<network>.coti.io (linux | mac).
installer_entrypoint_url() {
    local platform="$1"
    local network="${2:-${NETWORK:-testnet}}"
    printf 'https://fullnode.%s.coti.io/install-%s' "$network" "$platform"
}

_source_installer_helper() {
    local name="$1"
    local local_path="${SCRIPT_DIR:?SCRIPT_DIR must be set}/scripts/${name}"

    if [ -f "$local_path" ]; then
        # shellcheck source=/dev/null
        . "$local_path"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if curl -fsSL "${INSTALLER_REPO_RAW}/scripts/${name}" -o "$tmp"; then
        # shellcheck source=/dev/null
        . "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"

    printf '%s\n' "ERROR: Could not load scripts/${name} (missing ${local_path} and fetch from ${INSTALLER_REPO_RAW} failed)." >&2
    return 1
}
