[![COTI Website](https://img.shields.io/badge/COTI%20WEBSITE-4CAF50?style=for-the-badge)](https://coti.io)
[![image](https://img.shields.io/badge/Telegram-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://telegram.coti.io)
[![image](https://img.shields.io/badge/Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.coti.io)
[![image](https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white)](https://twitter.coti.io)
[![image](https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://youtube.coti.io)

# COTI Full Node

This repository contains the necessary files and scripts to easily set up and manage a COTI Full Node for the COTI blockchain network.

## Documentation

Visit the [Running a COTI Node](https://docs.coti.io/coti-documentation/running-a-coti-node) section of the COTI Documenation for full instructions.

### **Updating to the latest version**

To update your node to the latest version, follow these steps:

1.  **Clone or Pull Changes**: If you don't have the repository cloned, clone it. If you already have it, navigate to the directory and pull the latest changes.
    * **Clone**: `git clone https://github.com/coti-io/coti-full-node.git`
    * **Pull**: `cd ~/coti-full-node` and then `git pull`

2.  **Checkout the Tag**: Ensure you are on the correct version by checking out the new tag.
    `git checkout tags/v1.1.4-testnet`

3.  **Stop Old Containers**: Stop the existing containers by running the stop script.
    `./stop_coti-full-node.sh`

4.  **Start New Containers**: Start the new containers with the updated Docker Compose file.
    `./start_coti-full-node.sh`

### Reporting Issues

If you encounter any bugs or issues, please report them by [opening an issue](https://github.com/coti-io/coti-full-node/issues/new) on GitHub. Include as much detail as possible, including steps to reproduce the bug, the environment you encountered it in, and any other relevant information.

### FRPC RPC Relay (Testnet Gateway)

The stack can run an FRP client (`frpc`) container that creates an outbound-only tunnel from your node to `gateway.fullnode.testnet.coti.io:7000`.

- FRPC is used only for JSON-RPC relay to the node RPC service on port `8545`.
- P2P sync and peer connectivity still use the normal full-node bootnodes and port `7400`.
- You do not need inbound RPC ports on your home PC for this relay mode.
- Required outbound connectivity for relay is `gateway.fullnode.testnet.coti.io:7000`.
- Gateway-side routing can forward external requests (for example `https://<node-id>.fullnode.testnet.coti.io/rpc`) through FRPS to your FRPC client, then to the local full-node RPC endpoint.

Relevant environment variables are documented in `.env.example`.

### Operator status page

After `./start_coti-full-node.sh`, a small **local** web dashboard helps non-technical operators see whether the node is running, has peers, is syncing, and (when configured) whether DNS/HTTPS or the FRPC gateway look healthy. On the machine where Docker runs, open [http://127.0.0.1:8090](http://127.0.0.1:8090). It is bound to localhost only and auto-refreshes about every 15 seconds.

If you manage the server over SSH, use port forwarding, for example: `ssh -L 8090:127.0.0.1:8090 user@your-node` then open `http://127.0.0.1:8090` in your desktop browser.
