#!/bin/bash

# Resolve repo directory so this script works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Match start_coti-full-node.sh: installer defaults, then host .env.
if [ -f installer.env ] || [ -f .env ]; then
    set -a
    # shellcheck source=/dev/null
    [ -f installer.env ] && . ./installer.env
    # shellcheck source=/dev/null
    [ -f .env ] && . ./.env
    set +a
fi

# RPC/WS are fixed at 8545/8546 on the host (see docker-compose.yml).
RPC_URL="http://127.0.0.1:8545"

# Number of checks
CHECKS=5
# Interval between checks in seconds
INTERVAL=10

# Return block number as decimal (eth_blockNumber returns hex).
get_block_number_dec() {
    local hex raw
    raw=$(curl -fsS --connect-timeout 5 --max-time 15 -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null) || return 1
    hex=$(printf '%s' "$raw" | jq -r '.result // empty') || return 1
    if [[ ! "$hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
        return 1
    fi
    echo $((16#${hex#0x}))
}

initial_block=$(get_block_number_dec) || initial_block=""
if [ -z "$initial_block" ] || ! [[ "$initial_block" =~ ^[0-9]+$ ]]; then
    echo "Could not read a valid block number from $RPC_URL (is the RPC port up?)."
    exit 1
fi

echo "Initial block number: $initial_block"

# Monitor block progression
for (( i=1; i<=CHECKS; i++ )); do
    sleep "$INTERVAL"
    new_block=$(get_block_number_dec) || new_block=""
    echo "Check $i: Block number is ${new_block:-<unavailable>}"
    if [ -n "$new_block" ] && [[ "$new_block" =~ ^[0-9]+$ ]] && [ "$new_block" -gt "$initial_block" ]; then
        echo "Block number has progressed. Node is syncing."
        exit 0
    fi
done

echo "Block number did not change after $CHECKS checks. Node might not be syncing."
exit 1
