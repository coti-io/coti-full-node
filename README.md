[![COTI Website](https://img.shields.io/badge/COTI%20WEBSITE-4CAF50?style=for-the-badge)](https://coti.io)
[![image](https://img.shields.io/badge/Telegram-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://telegram.coti.io)
[![image](https://img.shields.io/badge/Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.coti.io)
[![image](https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white)](https://twitter.coti.io)
[![image](https://img.shields.io/badge/YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://youtube.coti.io)

# COTI Full Node

This repository contains the necessary files and scripts to easily set up and manage a COTI Full Node for the COTI blockchain network.

## Documentation

Visit the [Running a COTI Node](https://docs.coti.io/coti-documentation/running-a-coti-node) section of the COTI Documentation for full instructions. The [node ecosystem installation guides](https://github.com/coti-io/documentation/tree/main/node-ecosystem) describe wizard flows in more detail.

### Automated install (`install_coti-full-node.sh`)

Run from an **empty** directory. Set `<network>` to `testnet` or `mainnet`.

**Linux / WSL** (Ubuntu 24.04 LTS, or WSL with a Linux home path — not `/mnt/c/`) — as **root**:

```bash
curl -sL https://fullnode.<network>.coti.io/install-linux | sudo bash -s -- "0x<PRIVATE_KEY>" "<FQDN>" [options]
```

**macOS** — do not use `sudo`:

```bash
curl -sL https://fullnode.<network>.coti.io/install-mac | bash -s -- "0x<PRIVATE_KEY>" "<FQDN>" [options]
```

**Required arguments:** 64-character hex private key (optional `0x` prefix) and FQDN hostname.
Network selection is explicit via **`--testnet`** (default) or **`--mainnet`**.

| Flag | Purpose |
|------|---------|
| **`--with-frp`** | COTI wizard tunnel: enables FRPC + internal Nginx path gateway (no host TLS/certs), relaxes inbound 80/443/7400 firewall checks. |
| **`--with-nginx`** | Your domain: Nginx + Let’s Encrypt on the host (`/rpc`, `/ws`, `/metrics`, `/operator/`). |
| **`--staging`** | Let’s Encrypt staging CA (with `--with-nginx` only). |
| **`--testnet`**, **`--mainnet`** | Select chain profile in a single branch (image, network id, bootnodes, FRPS defaults, disk requirement). |
| **`--frpc-custom-domain=`**, **`--frpc-auth-token=`**, **`--frps-server-addr-1=`**, etc. | Optional FRPC tuning (see script). |

**Nginx/TLS and FRPC are off by default.** Use **`--with-nginx`** or **`--with-frp`** to enable them (not both on one install).

**macOS:** use `install_coti-full-node-mac.sh` (see script header for `curl` examples).

### Configuration files

After install, configuration lives in **`.env`** (this host) plus network profiles under **`networks/`** (chain defaults).

| File | Purpose |
|------|---------|
| **`.env`** | This host: `NETWORK`, `DOCKER_FULL_NODE_IMAGE_VERSION`, `FULLNODE_FQDN`, `FULLNODE_EXT_IP`, `NGINX_ENABLED`, `FRPC_ENABLED`, FRPS hosts, keys. |
| **`networks/<network>.env`** | Chain profile: bootnodes, network id, soda addresses, FRPS regional defaults, install disk requirement. |

`start_coti-full-node.sh` and `stop_coti-full-node.sh` load **`.env`**, then **`networks/<NETWORK>.env`**, then **`.env` again** (host values win on overlap).

**Upgrade the node image:** edit `DOCKER_FULL_NODE_IMAGE_VERSION` or set `IMAGE=` in `.env`, then `./stop_coti-full-node.sh` and `./start_coti-full-node.sh`.

Per-variable reference: [`.env.example`](.env.example).

### **Updating to the latest version**

To update your node to the latest version, follow these steps:

1.  **Clone or Pull Changes**: If you don't have the repository cloned, clone it. If you already have it, navigate to the directory and pull the latest changes.
    * **Clone**: `git clone https://github.com/coti-io/coti-full-node.git`
    * **Pull**: `cd ~/coti-full-node` and then `git pull`

2.  **Checkout the Tag**: Ensure you are on the correct version by checking out the new tag.
    `git checkout tags/v1.1.4-testnet`

3.  **Bump image tag** (if needed): set `DOCKER_FULL_NODE_IMAGE_VERSION` or `IMAGE` in `.env`.

4.  **Stop Old Containers**: Stop the existing containers by running the stop script.
    `./stop_coti-full-node.sh`

5.  **Start New Containers**: Start the new containers with the updated Docker Compose file.
    `./start_coti-full-node.sh`

### Reporting Issues

If you encounter any bugs or issues, please report them by [opening an issue](https://github.com/coti-io/coti-full-node/issues/new) on GitHub. Include as much detail as possible, including steps to reproduce the bug, the environment you encountered it in, and any other relevant information.

### FRPC RPC relay (testnet/mainnet gateway)

Enable with **`--with-frp`** (wizard tunnel). The stack runs an **internal Nginx gateway** (Docker-only, HTTP, no certificates) plus two `frpc` containers (regional gateways; defaults in `.env.example`).

- **Outbound-only** tunnel to FRPS (`FRPS_SERVER_ADDR_1` / `_2`, port `7000` by default).
- Traffic path: COTI edge → **frpc** → **internal Nginx** → full node / operator dashboard.
- Edge paths on your `FRPC_CUSTOM_DOMAIN`: **`/rpc`** → JSON-RPC, **`/ws`** → WebSocket, **`/metrics`** → Prometheus metrics, **`/operator/`** → local operator dashboard.
- P2P still uses bootnodes and host port **7400**; wizard tunnel mode does not require inbound 80/443/7400 from the internet.
- Host TLS Nginx (`--with-nginx`) and FRPC are **mutually exclusive** on the same install.

Relevant variables: `.env.example`. FRPC is off by default; use **`--with-frp`** to enable it.

### Operator status page

After `./start_coti-full-node.sh`, a small **local** web dashboard helps non-technical operators see whether the node is running, has peers, is syncing, and (when configured) whether DNS/HTTPS or the FRPC gateway look healthy. On the machine where Docker runs, open [http://127.0.0.1:8090](http://127.0.0.1:8090). It is bound to localhost only and auto-refreshes about every 15 seconds.

If you manage the server over SSH, use port forwarding, for example: `ssh -L 8090:127.0.0.1:8090 user@your-node` then open `http://127.0.0.1:8090` in your desktop browser.
