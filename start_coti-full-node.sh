#!/bin/bash

export FULLNODE_EXT_IP=$( curl -s https://api.ipify.org )

export FULLNODE_DNS_ADDRESS=$( dig -x $FULLNODE_EXT_IP +short | head -n 1 )

docker-compose up -d

./liveness_coti-full-node.sh
