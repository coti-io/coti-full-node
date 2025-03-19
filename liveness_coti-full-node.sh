#!/bin/bash

# Ethereum JSON-RPC endpoint (change this to your node's endpoint)
RPC_URL="http://localhost:8545"

# Number of checks
CHECKS=5
# Interval between checks in seconds
INTERVAL=10

# Function to get the current block number
get_block_number() {
    curl -s -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | \
        jq -r '.result' | xargs printf "%d\n"
}

# Initial block number
initial_block=$(get_block_number)

echo "Initial block number: $initial_block"

# Monitor block progression
for (( i=1; i<=$CHECKS; i++ )); do
    sleep $INTERVAL
    new_block=$(get_block_number)
    echo "Check $i: Block number is $new_block"
    if [ "$new_block" -gt "$initial_block" ]; then
        echo "Block number has progressed. Node is syncing."
        exit 0
    fi
done

echo "Block number did not change after $CHECKS checks. Node might not be syncing."
exit 1

