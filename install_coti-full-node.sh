#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- Terminal styling (no-op when stdout is not a TTY) ---
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    _B=$(tput bold 2>/dev/null || true)
    _D=$(tput dim 2>/dev/null || true)
    _U=$(tput smul 2>/dev/null || true)
    _R=$(tput sgr0 2>/dev/null || true)
    _C=$(tput setaf 6 2>/dev/null || true)
    _G=$(tput setaf 2 2>/dev/null || true)
    _Y=$(tput setaf 3 2>/dev/null || true)
else
    _B="" _D="" _U="" _R="" _C="" _G="" _Y=""
fi

_w() { printf '%s\n' "$*"; }
_banner_line() { printf '%s\n' "${_C}${_B}$*${_R}"; }
_div() { printf '%s\n' "${_D}────────────────────────────────────────────────────${_R}"; }

print_welcome() {
    _div
    _banner_line "  COTI Full Node — automated installer"
    _div
    _w ""
    _w "${_B}Planned steps${_R}"
    _w "  1. OS validation"
    _w "  2. Validate inputs (private key, FQDN)"
    _w "  3. Install host dependencies (Docker, tools)"
    _w "  4. Clone repository and prepare directory"
    _w "  5. Generate .env and node identity"
    _w "  6. Optional: Nginx + Let's Encrypt (${_Y}off by default${_R}; use ${_U}--with-nginx${_R} or ${_U}NGINX_ENABLED=true${_R})"
    _w "  7. Optional: FRPC (${_Y}off by default${_R}; ${_U}--with-frp${_R} = COTI wizard tunnel: FRPC on, no Nginx; ${_U}--frpc-enabled=true${_R} = FRPC relay only, no wizard)"
    _w "  8. Start the stack"
    _w ""
    _div
}

print_requirements() {
    _div
    _banner_line "  Requirements"
    _div
    _w "  • OS: Ubuntu 24.04 LTS (supported by COTI)"
    _w "  • Free disk: ${DISK_SPACE_REQUIRED} GB in the install directory"
    _w "  • Port 7400 must be free locally for the node container (P2P)"
    _w "  • ${_B}With Nginx/SSL:${_R} ports 80 and 443 free; firewall allows 80/443/7400"
    _w "  • ${_B}With --with-frp${_R} (COTI wizard tunnel): no Nginx on host; inbound 80/443/7400 on the ${_U}firewall${_R} not required (FRP + edge TLS)"
    _w "  • Without Nginx and without FRPC: RPC/WS on local ports (see success message)"
    _w ""
    _div
}

info() { printf '%s\n' "${_C}→${_R} $*"; }
ok() { printf '%s\n' "${_G}✓${_R} $*"; }

# Shown in help text (override if you mirror the installer elsewhere)
FULLNODE_INSTALLER_URL="${FULLNODE_INSTALLER_URL:-https://fullnode.testnet.coti.io}"

print_install_curl_examples() {
    _w "Linux, macOS, or Windows WSL (Ubuntu 24.04):"
    _w "  curl -sL ${FULLNODE_INSTALLER_URL} | sudo bash -s -- \"0x...\" \"your.domain\""
    _w ""
    _w "On WSL, run from a directory under your Linux home (e.g. ~/coti), not under /mnt/c/, so Docker can create Unix sockets for the node."
    _w "Native Windows is not supported for this installer; use WSL (Ubuntu 24.04) or a Linux host."
}

print_welcome
read -r -p "Press Enter to continue, or Ctrl+C to abort " < /dev/tty || true
_w ""

# Load installer configuration (if present) so key constants can be customized without editing this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALLER_ENV_FILE="$SCRIPT_DIR/installer.env"
if [ -f "$INSTALLER_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$INSTALLER_ENV_FILE"
fi

# Default values (can be overridden in installer.env)
: "${DISK_SPACE_REQUIRED:=90}"      # GB

print_requirements
read -r -p "Press Enter to continue, or Ctrl+C to abort " < /dev/tty || true
_w ""

_FRPS_SERVER_ADDR_1_FROM_ENV=false
_FRPS_SERVER_ADDR_2_FROM_ENV=false
# After sourcing installer.env: detect FRPS host vars before := defaults (matches empty assignment)
if declare -p FRPS_SERVER_ADDR_1 >/dev/null 2>&1; then
    _FRPS_SERVER_ADDR_1_FROM_ENV=true
fi
if declare -p FRPS_SERVER_ADDR_2 >/dev/null 2>&1; then
    _FRPS_SERVER_ADDR_2_FROM_ENV=true
fi

: "${DOCKER_FULL_NODE_IMAGE_VERSION:=1.2.0}"
# IMAGE (optional, in installer.env) overrides DOCKER_FULL_NODE_IMAGE_VERSION for upgrades.
DOCKER_FULL_NODE_IMAGE_VERSION="${IMAGE:-$DOCKER_FULL_NODE_IMAGE_VERSION}"
: "${CLONE_BRANCH:=coti-testnet}"
# Default network label for this installer package (mainnet builds set NETWORK=mainnet here).
: "${NETWORK:=testnet}"
: "${NGINX_ENABLED:=false}"
: "${FRPC_ENABLED:=false}"
: "${FRPS_SERVER_ADDR:=}"
: "${FRPS_SERVER_ADDR_1:=virginia.fullnode.testnet.coti.io}"
: "${FRPS_SERVER_ADDR_2:=frankfurt.fullnode.testnet.coti.io}"
: "${FRPS_SERVER_PORT:=7000}"
: "${FRPC_CUSTOM_DOMAIN:=}"
: "${FRPC_AUTH_TOKEN:=}"
: "${COTI_FULL_NODE_RPC_LOCAL_PORT:=8545}"

# --- ROOT CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "${_Y}This script must be run as root.${_R}"
    _w ""
    print_install_curl_examples
    exit 1
fi

# Split flags from positional arguments (flags may appear before or after PK/FQDN)
FRPS_SERVER_ADDR_1_EXPLICIT=false
FRPS_SERVER_ADDR_2_EXPLICIT=false
COTI_TUNNEL_INSTALL=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --without-nginx)
            NGINX_ENABLED=false
            ;;
        --with-nginx)
            NGINX_ENABLED=true
            COTI_TUNNEL_INSTALL=false
            ;;
        --nginx-enabled=*)
            NGINX_ENABLED="${arg#*=}"
            if [[ "$NGINX_ENABLED" == "true" ]]; then
                COTI_TUNNEL_INSTALL=false
            fi
            ;;
        --staging)
            CERTBOT_STAGING=true
            ;;
        --with-frp)
            FRPC_ENABLED=true
            NGINX_ENABLED=false
            COTI_TUNNEL_INSTALL=true
            ;;
        --without-frp)
            FRPC_ENABLED=false
            COTI_TUNNEL_INSTALL=false
            ;;
        --frpc-enabled=*)
            FRPC_ENABLED="${arg#*=}"
            if [[ "$FRPC_ENABLED" != "true" ]]; then
                COTI_TUNNEL_INSTALL=false
            fi
            ;;
        --frpc-custom-domain=*)
            FRPC_CUSTOM_DOMAIN="${arg#*=}"
            ;;
        --frpc-auth-token=*)
            FRPC_AUTH_TOKEN="${arg#*=}"
            ;;
        --frps-server-addr=*)
            FRPS_SERVER_ADDR="${arg#*=}"
            ;;
        --frps-server-addr-1=*)
            FRPS_SERVER_ADDR_1="${arg#*=}"
            FRPS_SERVER_ADDR_1_EXPLICIT=true
            ;;
        --frps-server-addr-2=*)
            FRPS_SERVER_ADDR_2="${arg#*=}"
            FRPS_SERVER_ADDR_2_EXPLICIT=true
            ;;
        --frps-server-port=*)
            FRPS_SERVER_PORT="${arg#*=}"
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done

PK="${POSITIONAL[0]:-}"
FQDN="${POSITIONAL[1]:-}"

if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && [[ "$FRPC_ENABLED" != "true" ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} COTI tunnel install requires FRPC enabled (use ${_U}--with-frp${_R})."
    exit 1
fi

# Legacy single gateway: apply FRPS_SERVER_ADDR where a region host was not set (installer.env) or overridden (CLI).
if [ -n "${FRPS_SERVER_ADDR:-}" ]; then
    if [[ "$FRPS_SERVER_ADDR_1_EXPLICIT" != "true" ]] && [[ "$_FRPS_SERVER_ADDR_1_FROM_ENV" != "true" ]]; then
        FRPS_SERVER_ADDR_1="$FRPS_SERVER_ADDR"
    fi
    if [[ "$FRPS_SERVER_ADDR_2_EXPLICIT" != "true" ]] && [[ "$_FRPS_SERVER_ADDR_2_FROM_ENV" != "true" ]]; then
        FRPS_SERVER_ADDR_2="$FRPS_SERVER_ADDR"
    fi
fi

_div
_banner_line "  Installing COTI Full Node"
_div
_w ""

# --- 0. OS VALIDATION ---
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^24\.04 ]]; then
        printf '%s\n' "${_Y}Warning:${_R} This script targets Ubuntu 24.04 LTS."
        printf '%s\n' "Detected: $PRETTY_NAME"
        read -r -p "Proceed anyway? (y/N): " PROCEED < /dev/tty
        if [[ ! "$PROCEED" =~ ^[yY] ]]; then
            _w "Aborted."
            exit 1
        fi
    fi
fi

# --- 1. VALIDATE REQUIRED INPUTS (PK, FQDN as args) ---
if [ -z "$FQDN" ] || [ -z "$PK" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Private key and FQDN are required."
    _w ""
    print_install_curl_examples
    _w ""
    _w "With Nginx + Let's Encrypt, append after the FQDN: --with-nginx"
    _w "Wizard tunnel (COTI subdomain + FRPC, no host TLS): --with-frp"
    exit 1
fi

# Strip 0x prefix from PK for nodekey format
PK_CLEAN="${PK#0x}"

# Validate PK: must be exactly 64 hexadecimal characters (32 bytes)
if [[ ! "$PK_CLEAN" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} Private key must be 64 hex characters (32 bytes), with optional 0x prefix."
    printf '%s\n' "Got ${#PK_CLEAN} hex characters after stripping 0x."
    exit 1
fi

# Validate FQDN: hostname only (alphanumeric, hyphens, dots); prevents injection
if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [ "${#FQDN}" -gt 253 ]; then
    printf '%s\n' "${_Y}ERROR:${_R} FQDN must be a valid hostname (letters, numbers, hyphens, dots; 1–253 chars)."
    _w "Example: node1.fullnode.testnet.coti.io"
    exit 1
fi

# Validate NGINX_ENABLED.
if [[ ! "$NGINX_ENABLED" =~ ^(true|false)$ ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} NGINX_ENABLED must be 'true' or 'false'."
    exit 1
fi

# Validate FRPC settings.
if [[ ! "$FRPC_ENABLED" =~ ^(true|false)$ ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} FRPC_ENABLED must be 'true' or 'false'."
    exit 1
fi

if [[ "$FRPC_ENABLED" == "true" ]] && [ -z "$FRPC_CUSTOM_DOMAIN" ]; then
    FRPC_CUSTOM_DOMAIN="$FQDN"
fi

if [[ ! "$FRPS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$FRPS_SERVER_PORT" -lt 1 ] || [ "$FRPS_SERVER_PORT" -gt 65535 ]; then
    printf '%s\n' "${_Y}ERROR:${_R} FRPS_SERVER_PORT must be a valid TCP port (1–65535)."
    exit 1
fi

if [[ ! "$COTI_FULL_NODE_RPC_LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$COTI_FULL_NODE_RPC_LOCAL_PORT" -lt 1 ] || [ "$COTI_FULL_NODE_RPC_LOCAL_PORT" -gt 65535 ]; then
    printf '%s\n' "${_Y}ERROR:${_R} COTI_FULL_NODE_RPC_LOCAL_PORT must be a valid TCP port (1–65535)."
    exit 1
fi

info "Install mode: Nginx/SSL ${_B}${NGINX_ENABLED}${_R} · FRPC relay ${_B}${FRPC_ENABLED}${_R}$([[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && printf ' · %s' "${_B}COTI tunnel (wizard)${_R}")"
_w ""

# --- 1b. CHECK INSTALL DIRECTORY (writability + disk space) ---
INSTALL_DIR="$(pwd)"
if [ ! -w "$INSTALL_DIR" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Cannot write to current directory ($INSTALL_DIR)."
    _w "Run the installer from a writable directory (for example cd ~)."
    exit 1
fi

REQUIRED_KB=$((DISK_SPACE_REQUIRED * 1024 * 1024))
AVAIL_KB=$(df -P "$INSTALL_DIR" | awk 'NR==2 {print $4}')
if [ -z "$AVAIL_KB" ] || [ "$AVAIL_KB" -lt "$REQUIRED_KB" ]; then
    if [ -n "$AVAIL_KB" ]; then
        AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
        printf '%s\n' "${_Y}ERROR:${_R} Need at least ${DISK_SPACE_REQUIRED} GB free in $INSTALL_DIR (about ${AVAIL_GB} GB available)."
    else
        printf '%s\n' "${_Y}ERROR:${_R} Could not read free disk space for $INSTALL_DIR."
    fi
    exit 1
fi

# --- 1c. CHECK NGINX PORTS (80, 443) ARE AVAILABLE ---
if [[ "$NGINX_ENABLED" == "true" ]]; then
    NGINX_PORTS="80 443"
    for port in $NGINX_PORTS; do
        if ss -tlnp 2>/dev/null | grep -qE ":$port\s"; then
            printf '%s\n' "${_Y}ERROR:${_R} Port $port is in use. Nginx needs 80 and 443 free."
            exit 1
        fi
    done
fi

# --- 1e. CHECK PORT 7400 IS AVAILABLE ---
if ss -tlnp 2>/dev/null | grep -qE ':7400(\s|$)'; then
    printf '%s\n' "${_Y}ERROR:${_R} Port 7400 is already in use."
    exit 1
fi

# --- 1d/1f. CHECK FIREWALL/ IPTABLES RULES FOR REQUIRED PORTS ---
# COTI tunnel (--with-frp): public RPC/HTTPS and much of P2P reachability go via FRP; skip inbound FW checks.
if [[ "${COTI_TUNNEL_INSTALL:-false}" != "true" ]]; then
# Only perform ufw checks if ufw is installed and active.
if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi "Status: active"; then
        # For nginx mode, ensure there are no DENY/REJECT rules on 80 or 443.
        if [[ "$NGINX_ENABLED" == "true" ]]; then
            if ufw status | awk '$1 == "80/tcp"  && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
                printf '%s\n' "${_Y}ERROR:${_R} ufw is blocking port 80."
                exit 1
            fi
            if ufw status | awk '$1 == "443/tcp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
                printf '%s\n' "${_Y}ERROR:${_R} ufw is blocking port 443."
                exit 1
            fi
        fi

        # For the node’s UDP/TCP port 7400, also ensure no DENY/REJECT rules.
        if ufw status | awk '$1 == "7400/udp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
            printf '%s\n' "${_Y}ERROR:${_R} ufw is blocking 7400/udp."
            exit 1
        fi
        if ufw status | awk '$1 == "7400/tcp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
            printf '%s\n' "${_Y}ERROR:${_R} ufw is blocking 7400/tcp."
            exit 1
        fi
    fi
fi

# Check for iptables rules that explicitly block port 7400 (DROP or REJECT only).
# Do not flag chain jumps (e.g. ufw-user-input) or LOG rules, which do not block.
# exit !found: when blocking found, exit 0 so we run the error block; when not found, exit 1 so we continue
if command -v iptables >/dev/null 2>&1; then
    if iptables -L -n 2>/dev/null | awk '/dpt:7400/ && ($1 == "DROP" || $1 == "REJECT") {found=1} END {exit !found}'; then
        printf '%s\n' "${_Y}ERROR:${_R} iptables appears to block port 7400."
        exit 1
    fi
fi
fi

# --- 2. INSTALL HOST DEPENDENCIES ---
info "Installing system packages..."
# Ensure package index is up to date before installing dependencies.
apt-get update -y

# Detect if Docker is already installed (from Docker's repo or Ubuntu's).
# Installing docker.io when containerd.io is present causes: containerd.io : Conflicts: containerd
DOCKER_PRESENT=false
if command -v docker >/dev/null 2>&1; then
    DOCKER_PRESENT=true
elif [ -S /var/run/docker.sock ]; then
    DOCKER_PRESENT=true
elif dpkg -s containerd.io >/dev/null 2>&1; then
    DOCKER_PRESENT=true
fi

# Detect necessary system dependencies
PKGS="curl git jq dnsutils"
if [[ "$DOCKER_PRESENT" == "true" ]]; then
    info "Docker already present — skipping docker.io (avoids containerd.io conflict)"
else
    PKGS="docker.io docker-compose $PKGS"
fi

if [[ "$NGINX_ENABLED" == "true" ]]; then
    PKGS="certbot $PKGS"
fi

# Install necessary system dependencies
apt-get install -y --no-install-recommends $PKGS

# Set the compose command
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    DC="docker-compose"
fi

# --- 3. CLONE/PREPARE DIRECTORY ---
# Require a clean directory: no existing clone (avoids old-version conflicts).
if [ -f "docker-compose.yml" ] || [ -d "coti-full-node" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Current directory is not clean for a fresh install."
    _w "  • docker-compose.yml present, or"
    _w "  • coti-full-node/ already exists"
    _w "Use an empty directory and run again."
    exit 1
fi

info "Cloning coti-full-node (${CLONE_BRANCH})..."
git clone -b "$CLONE_BRANCH" https://github.com/coti-io/coti-full-node.git
cd coti-full-node

# Persist installation-level settings into the clone (image tag, network, etc.).
# Per-host values go in .env; operators upgrade the container image by editing DOCKER_FULL_NODE_IMAGE_VERSION or IMAGE here.
info "Writing installer.env (installation metadata)..."
cat <<EOF > installer.env
# Installation / packaging defaults for this checkout (not host-specific).
# Per-host settings are in .env (sourced after this file by start/stop scripts).
#
# Bump DOCKER_FULL_NODE_IMAGE_VERSION (or set IMAGE=) to upgrade the node image, then run ./start_coti-full-node.sh

DISK_SPACE_REQUIRED=${DISK_SPACE_REQUIRED}
DOCKER_FULL_NODE_IMAGE_VERSION=${DOCKER_FULL_NODE_IMAGE_VERSION}
CLONE_BRANCH=${CLONE_BRANCH}
NETWORK=${NETWORK}
EOF

# --- 4. GENERATE .ENV FILE ---
info "Writing .env..."
if ! EXT_IP=$(curl -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org); then
    printf '%s\n' "${_Y}ERROR:${_R} Could not detect public IP (api.ipify.org). Check outbound HTTPS and re-run."
    exit 1
fi
if [ -z "$EXT_IP" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Public IP lookup returned an empty response."
    exit 1
fi

cat <<EOF > .env
FULLNODE_EXT_IP=$EXT_IP
FULLNODE_FQDN=$FQDN
NGINX_ENABLED=$NGINX_ENABLED
FRPC_ENABLED=$FRPC_ENABLED
FRPS_SERVER_ADDR=$FRPS_SERVER_ADDR
FRPS_SERVER_ADDR_1=$FRPS_SERVER_ADDR_1
FRPS_SERVER_ADDR_2=$FRPS_SERVER_ADDR_2
FRPS_SERVER_PORT=$FRPS_SERVER_PORT
FRPC_CUSTOM_DOMAIN=$FRPC_CUSTOM_DOMAIN
FRPC_AUTH_TOKEN=$FRPC_AUTH_TOKEN
COTI_FULL_NODE_RPC_LOCAL_PORT=$COTI_FULL_NODE_RPC_LOCAL_PORT
EOF

# --- 5. CONFIGURE PRIVATE KEY (NODEKEY) ---
info "Writing node key..."
# Ethereum/Geth based clients read the nodekey from a file
echo -n "$PK_CLEAN" > ./nodekey

# --- 5b. CONFIGURE FRPC (RPC RELAY ONLY) ---
if [[ "$FRPC_ENABLED" == "true" ]]; then
    FRPC_AUTH_BLOCK=""
    if [ -n "$FRPC_AUTH_TOKEN" ]; then
        FRPC_AUTH_BLOCK=$(cat <<EOF
auth.method = "token"
auth.token = "$FRPC_AUTH_TOKEN"
EOF
)
    fi

    for _frpc_toml_pair in \
        "frpc-1.toml:$FRPS_SERVER_ADDR_1" \
        "frpc-2.toml:$FRPS_SERVER_ADDR_2"; do
        _frpc_toml_file="${_frpc_toml_pair%%:*}"
        _frpc_server_addr="${_frpc_toml_pair#*:}"
        cat <<EOF > "./$_frpc_toml_file"
serverAddr = "$_frpc_server_addr"
serverPort = $FRPS_SERVER_PORT
$FRPC_AUTH_BLOCK

[[proxies]]
name = "$FRPC_CUSTOM_DOMAIN"
type = "http"
localIP = "coti-${NETWORK}-full-node"
localPort = 8545
customDomains = ["$FRPC_CUSTOM_DOMAIN"]
EOF
    done
    unset _frpc_toml_pair _frpc_toml_file _frpc_server_addr
fi

# --- 6-8. SSL AND NGINX SETUP (skipped when NGINX_ENABLED=false) ---
if [[ "$NGINX_ENABLED" == "true" ]]; then
    info "Preparing Let's Encrypt HTTP-01 challenge..."
    mkdir -p ./nginx/certbot ./nginx/sites-enabled

    # Start temporary nginx-init (profile: setup) - serves only port 80 for ACME challenge
    info "Starting temporary Nginx for ACME..."
    $DC --profile setup up -d nginx-init

    # --- 7. RUN CERTBOT ---
    CERTBOT_EXTRA=""
    if [[ "$CERTBOT_STAGING" == "true" ]]; then
        info "Requesting certificate for $FQDN (${_Y}Let's Encrypt staging${_R} — not browser-trusted)..."
        CERTBOT_EXTRA="--staging"
    else
        info "Requesting certificate for $FQDN..."
    fi
    certbot certonly --webroot -w "$(pwd)/nginx/certbot" -d "$FQDN" $CERTBOT_EXTRA --register-unsafely-without-email --agree-tos --non-interactive

    # Tear down temporary nginx-init so port 80 is free for main nginx
    info "Stopping temporary Nginx..."
    $DC --profile setup down

    # --- 8. APPLY FINAL NGINX CONFIG ---
    info "Writing Nginx TLS proxy config..."
    cat <<EOF > ./nginx/sites-enabled/fullnode.conf

upstream fullnode_8545 {
    server coti-$NETWORK-full-node:8545  max_fails=3 fail_timeout=30s;
}

upstream fullnode_8546 {
    server coti-$NETWORK-full-node:8546  max_fails=3 fail_timeout=30s;
}

upstream fullnode_6000 {
    server coti-$NETWORK-full-node:6000  max_fails=3 fail_timeout=30s;
}

server {
    listen 443 ssl;
    server_name $FQDN;

    ssl_certificate     /etc/letsencrypt/live/$FQDN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FQDN/privkey.pem;
    ssl_session_timeout 5m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;

    location /ws {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_pass http://fullnode_8546/; 
    }

    location /rpc {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://fullnode_8545/;
    }

    location /metrics {
        proxy_set_header Host \$host;
        proxy_pass http://fullnode_6000/debug/metrics/prometheus;
    }
}

server {
    listen 80;
    server_name $FQDN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
fi

# --- 9. FINAL LAUNCH ---
info "Starting the full node stack..."
./start_coti-full-node.sh

_w ""
_div
ok "COTI full node is starting."
_w ""
if [[ "$NGINX_ENABLED" != "true" ]]; then
    _w "  • Mode: ${_B}no Nginx/SSL on this host${_R}"
    if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && [[ "$FRPC_ENABLED" == "true" ]]; then
        _w "  • COTI tunnel: public HTTPS/RPC at ${_B}https://${FRPC_CUSTOM_DOMAIN:-$FQDN}${_R} (edge TLS + DNS by COTI; FRPC to this node)"
    else
        _w "  • RPC / WS: published on host ports ${COTI_FULL_NODE_RPC_LOCAL_PORT} / 8546 (see docker-compose)"
    fi
else
    _w "  • HTTPS: ${_B}https://$FQDN${_R}"
fi
if [[ "$FRPC_ENABLED" == "true" ]]; then
    _w "  • FRPC: ${_B}enabled${_R} — gateways $FRPS_SERVER_ADDR_1:$FRPS_SERVER_PORT, $FRPS_SERVER_ADDR_2:$FRPS_SERVER_PORT"
    _w "  • FRPC custom domain (proxy name): ${FRPC_CUSTOM_DOMAIN}"
    if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]]; then
        _w "  • Inbound firewall: ${_B}not required${_R} for 80/443/7400 from the internet (outbound FRP + local P2P)"
    fi
else
    _w "  • FRPC: ${_D}disabled${_R} (wizard tunnel: ${_U}--with-frp${_R}; relay only: ${_U}--frpc-enabled=true${_R})"
fi
_w "  • Logs: ${_U}docker logs -f coti-$NETWORK-full-node${_R}"
_div
