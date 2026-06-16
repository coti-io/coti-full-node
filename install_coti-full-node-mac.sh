#!/bin/bash
# COTI Full Node — macOS installer (standalone; use install_coti-full-node.sh on Ubuntu/WSL).
set -e

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

info() { printf '%s\n' "${_C}→${_R} $*"; }
ok() { printf '%s\n' "${_G}✓${_R} $*"; }

# Free KiB on the filesystem backing Docker images/volumes (named chain data volumes live here).
_docker_engine_avail_kb() {
    local root kb
    docker info >/dev/null 2>&1 || return 1
    root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null) || return 1
    [ -n "$root" ] || return 1
    root="${root%/}"
    kb=$(docker run --rm -v /:/host:ro alpine:3.20 sh -c "df -Pk '/host${root}' 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null || true)
    if [ -n "$kb" ] && [ "$kb" -ge 1 ] 2>/dev/null; then
        printf '%s\n' "$kb"
        return 0
    fi
    if [ -e "$root" ]; then
        kb=$(df -k "$root" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$kb" ] && [ "$kb" -ge 1 ] 2>/dev/null; then
            printf '%s\n' "$kb"
            return 0
        fi
    fi
    return 1
}

# macOS: true if something is listening on TCP port $1
_tcp_port_in_use() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

print_welcome() {
    _div
    _banner_line "  COTI Full Node — macOS installer"
    _div
    _w ""
    _w "${_B}Planned steps${_R}"
    _w "  1. OS validation (macOS)"
    _w "  2. Validate inputs (private key, FQDN)"
    _w "  3. Check Docker + install tools (Homebrew) if needed"
    _w "  4. Clone repository and prepare directory"
    _w "  5. Generate .env and node identity"
    _w "  6. Optional: Nginx + Let's Encrypt (${_Y}off by default${_R}; ${_U}--with-nginx${_R})"
    _w "  7. Optional: FRPC / COTI wizard tunnel + internal Nginx gateway (${_Y}off by default${_R}; ${_U}--with-frp${_R}; no host TLS/certs)"
    _w "  8. Start the stack"
    _w ""
    _div
}

print_requirements() {
    _div
    _banner_line "  Requirements (macOS)"
    _div
    _w "  • ${_B}Docker${_R} installed ${_B}before${_R} you run this script (this installer does not install Docker). Use Docker Desktop or Colima; \`docker\` and \`docker compose\` must work"
    _w "  • ${_B}Homebrew${_R} (https://brew.sh) — used to install jq, certbot (if Nginx), git if missing"
    _w "  • ${_B}Nginx + TLS:${_R} certificates and Certbot state live under ${_U}./nginx/letsencrypt*${_R} in the clone (no elevated privileges in this script)"
    _w "  • Free disk: ${DISK_SPACE_REQUIRED} GB where Docker stores images/volumes (chain data uses a named volume, not the project folder)"
    _w "  • Port 7400 must be free on the host for published P2P (see docker-compose)"
    _w "  • ${_B}With Nginx/SSL:${_R} host ports 80 and 443 free"
    _w "  • ${_B}With --with-frp${_R}: COTI wizard tunnel — internal Nginx for path rewrite (no host TLS/certs); inbound 80/443/7400 not required on your router"
    _w ""
    _div
}

print_install_curl_examples() {
    local url="https://fullnode.<network>.coti.io/install-mac"
    if declare -f installer_entrypoint_url >/dev/null 2>&1; then
        url="$(installer_entrypoint_url mac)"
    fi
    _w "macOS:"
    _w "  curl -sL ${url} | bash -s -- \"0x...\" \"your.domain\" [--testnet|--mainnet] [options]"
}

# --- 0a. OS: Darwin only ---
if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} This script is for macOS only."
    _w "On Ubuntu or WSL, use install_coti-full-node.sh (with sudo)."
    exit 1
fi

# Non-interactive bash (e.g. `curl … | bash`) often inherits a minimal PATH. Docker Desktop and Homebrew install CLIs here.
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:${HOME}/.docker/bin:${PATH}"

# --- 0b. Do not run as root (Homebrew; Docker Desktop) ---
if [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Do not run this macOS installer as root or with sudo."
    _w ""
    print_install_curl_examples
    exit 1
fi

print_welcome
read -r -p "Press Enter to continue, or Ctrl+C to abort " < /dev/tty || true
_w ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALLER_REPO_RAW="${INSTALLER_REPO_RAW:-https://raw.githubusercontent.com/coti-io/coti-full-node/main}"

if [ -f "${SCRIPT_DIR}/scripts/source-installer-helper.sh" ]; then
    # shellcheck source=scripts/source-installer-helper.sh
    . "${SCRIPT_DIR}/scripts/source-installer-helper.sh"
else
    _installer_helper_tmp="$(mktemp)"
    if ! curl -fsSL "${INSTALLER_REPO_RAW}/scripts/source-installer-helper.sh" -o "$_installer_helper_tmp"; then
        rm -f "$_installer_helper_tmp"
        printf '%s\n' "ERROR: Could not bootstrap installer helpers from ${INSTALLER_REPO_RAW}." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$_installer_helper_tmp"
    rm -f "$_installer_helper_tmp"
fi

# Network: required --testnet/--mainnet for local runs; auto-detect for piped curl installs.
_source_installer_helper resolve-network.sh || exit 1
resolve_network "${BASH_SOURCE[0]:-$0}" "$@" || exit 1

_source_installer_helper load-network.sh || exit 1
load_network_profile "$NETWORK" "$SCRIPT_DIR"

FQDN_EXAMPLE="${FQDN_EXAMPLE:-node1.fullnode.${NETWORK}.coti.io}"

print_requirements
read -r -p "Press Enter to continue, or Ctrl+C to abort " < /dev/tty || true
_w ""

_FRPS_SERVER_ADDR_1_FROM_ENV=false
_FRPS_SERVER_ADDR_2_FROM_ENV=false
if declare -p FRPS_SERVER_ADDR_1 >/dev/null 2>&1; then
    _FRPS_SERVER_ADDR_1_FROM_ENV=true
fi
if declare -p FRPS_SERVER_ADDR_2 >/dev/null 2>&1; then
    _FRPS_SERVER_ADDR_2_FROM_ENV=true
fi

: "${DOCKER_FULL_NODE_IMAGE_VERSION:=1.2.0}"
DOCKER_FULL_NODE_IMAGE_VERSION="${IMAGE:-$DOCKER_FULL_NODE_IMAGE_VERSION}"
: "${NGINX_ENABLED:=false}"
: "${FRPC_ENABLED:=false}"
: "${FRPS_SERVER_ADDR:=}"
: "${FRPS_SERVER_PORT:=7000}"
: "${FRPC_CUSTOM_DOMAIN:=}"
: "${FRPC_AUTH_TOKEN:=}"

FRPS_SERVER_ADDR_1_EXPLICIT=false
FRPS_SERVER_ADDR_2_EXPLICIT=false
COTI_TUNNEL_INSTALL=false
_CLI_NGINX_ENABLE=false
_CLI_FRPC_ENABLE=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --testnet|--mainnet)
            ;;
        --with-nginx)
            NGINX_ENABLED=true
            COTI_TUNNEL_INSTALL=false
            _CLI_NGINX_ENABLE=true
            ;;
        --staging)
            CERTBOT_STAGING=true
            ;;
        --with-frp)
            FRPC_ENABLED=true
            NGINX_ENABLED=false
            COTI_TUNNEL_INSTALL=true
            _CLI_FRPC_ENABLE=true
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

if [[ "$_CLI_NGINX_ENABLE" == "true" && "$_CLI_FRPC_ENABLE" == "true" ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} Cannot combine host Nginx/SSL with FRPC on the same install."
    _w "  • Host TLS (Let's Encrypt on this machine): ${_U}--with-nginx${_R} only"
    _w "  • COTI wizard tunnel (FRP, no host Nginx): ${_U}--with-frp${_R} only"
    exit 1
fi

if [[ "$NGINX_ENABLED" == "true" && "$FRPC_ENABLED" == "true" ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} Nginx/SSL and FRPC cannot both be enabled."
    _w "  • Use only one: ${_U}--with-nginx${_R} (host TLS) or ${_U}--with-frp${_R} (COTI tunnel)."
    _w "  • If both are set via environment or .env, unset one before running."
    exit 1
fi

if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && [[ "$FRPC_ENABLED" != "true" ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} COTI tunnel install requires FRPC enabled (use ${_U}--with-frp${_R})."
    exit 1
fi

if [ -n "${FRPS_SERVER_ADDR:-}" ]; then
    if [[ "$FRPS_SERVER_ADDR_1_EXPLICIT" != "true" ]] && [[ "$_FRPS_SERVER_ADDR_1_FROM_ENV" != "true" ]]; then
        FRPS_SERVER_ADDR_1="$FRPS_SERVER_ADDR"
    fi
    if [[ "$FRPS_SERVER_ADDR_2_EXPLICIT" != "true" ]] && [[ "$_FRPS_SERVER_ADDR_2_FROM_ENV" != "true" ]]; then
        FRPS_SERVER_ADDR_2="$FRPS_SERVER_ADDR"
    fi
fi

_div
_banner_line "  Installing COTI Full Node (macOS)"
_div
_w ""

# --- 0c. Optional macOS version notice ---
MACOS_VER="$(sw_vers -productVersion 2>/dev/null || printf '%s' "unknown")"
info "Detected macOS ${MACOS_VER}"

# --- 1. VALIDATE REQUIRED INPUTS ---
if [ -z "$FQDN" ] || [ -z "$PK" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Private key and FQDN are required."
    _w ""
    print_install_curl_examples
    _w ""
    _w "Network (local run): --testnet or --mainnet (required)"
    _w "Network (curl install): inferred from FQDN, or pass --testnet / --mainnet"
    _w "With Nginx + Let's Encrypt: append ${_U}--with-nginx${_R}"
    _w "Wizard tunnel: ${_U}--with-frp${_R}"
    exit 1
fi

PK_CLEAN="${PK#0x}"

if [[ ! "$PK_CLEAN" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} Private key must be 64 hex characters (32 bytes), with optional 0x prefix."
    printf '%s\n' "Got ${#PK_CLEAN} hex characters after stripping 0x."
    exit 1
fi

if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [ "${#FQDN}" -gt 253 ]; then
    printf '%s\n' "${_Y}ERROR:${_R} FQDN must be a valid hostname (letters, numbers, hyphens, dots; 1–253 chars)."
    _w "Example: ${FQDN_EXAMPLE}"
    exit 1
fi

if [[ ! "$NGINX_ENABLED" =~ ^(true|false)$ ]]; then
    printf '%s\n' "${_Y}ERROR:${_R} NGINX_ENABLED must be 'true' or 'false'."
    exit 1
fi

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

info "Install mode: network ${_B}${NETWORK}${_R} (${NETWORK_SOURCE}) · Nginx/SSL ${_B}${NGINX_ENABLED}${_R} · FRPC relay ${_B}${FRPC_ENABLED}${_R}$([[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && printf ' · %s' "${_B}COTI tunnel (wizard)${_R}")"
_w ""

INSTALL_DIR="$(pwd)"
if [ ! -w "$INSTALL_DIR" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Cannot write to current directory ($INSTALL_DIR)."
    _w "Run from a writable directory (for example cd ~ && mkdir coti && cd coti)."
    exit 1
fi

if [[ "$NGINX_ENABLED" == "true" ]]; then
    for port in 80 443; do
        if _tcp_port_in_use "$port"; then
            printf '%s\n' "${_Y}ERROR:${_R} Port $port is in use. Nginx needs 80 and 443 free on the Mac."
            exit 1
        fi
    done
fi

if _tcp_port_in_use 7400; then
    printf '%s\n' "${_Y}ERROR:${_R} Port 7400 is already in use on the Mac."
    exit 1
fi

# macOS: skip Linux ufw/iptables checks

# --- 2. DOCKER + HOMEBREW DEPENDENCIES ---
if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "${_Y}ERROR:${_R} \`docker\` not found (not on PATH)."
    _w "This installer does ${_B}not${_R} install Docker (unlike the Ubuntu installer, which can install docker.io via apt)."
    _w "Install Docker yourself, then re-run. Examples:"
    _w "  • ${_B}Docker Desktop:${_R} https://www.docker.com/products/docker-desktop/ — or, with Homebrew: ${_U}brew install --cask docker${_R} then open Docker from Applications once."
    _w "  • ${_B}Colima:${_R} ${_U}brew install colima docker${_R} then ${_U}colima start${_R}"
    _w "If \`docker\` works in Terminal but failed here, PATH was too small for a piped script; this script already prepends common install locations."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    printf '%s\n' "${_Y}ERROR:${_R} Docker daemon is not reachable. Start Docker Desktop (or your engine) and try again."
    exit 1
fi

REQUIRED_KB=$((DISK_SPACE_REQUIRED * 1024 * 1024))
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
AVAIL_KB=$(_docker_engine_avail_kb || true)
if [ -z "$AVAIL_KB" ] || [ "$AVAIL_KB" -lt "$REQUIRED_KB" ]; then
    if [ -n "$AVAIL_KB" ]; then
        AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
        printf '%s\n' "${_Y}ERROR:${_R} Need at least ${DISK_SPACE_REQUIRED} GB free where Docker stores data (engine root: ${DOCKER_ROOT:-unknown}; about ${AVAIL_GB} GB available)."
    else
        printf '%s\n' "${_Y}ERROR:${_R} Could not read free disk space for the Docker engine (DockerRootDir: ${DOCKER_ROOT:-unknown}). Ensure Docker works and outbound image pulls are allowed (uses a short alpine:3.20 run)."
    fi
    exit 1
fi
ok "Docker engine disk: enough free space for chain data (named volume on ${DOCKER_ROOT:-Docker storage})"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
else
    printf '%s\n' "${_Y}ERROR:${_R} \`docker compose\` (Compose v2 plugin) is not available."
    _w "Update Docker Desktop or Colima so \`docker compose\` works, then re-run."
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    printf '%s\n' "${_Y}ERROR:${_R} Homebrew not found (brew)."
    _w "Install from https://brew.sh then ensure brew is on your PATH and re-run."
    exit 1
fi

_brew_install_if_missing() {
    local formula="$1"
    if brew list --formula "$formula" >/dev/null 2>&1; then
        return 0
    fi
    info "Installing $formula via Homebrew..."
    brew install "$formula"
}

if ! command -v git >/dev/null 2>&1; then
    _brew_install_if_missing git
fi
if ! command -v jq >/dev/null 2>&1; then
    _brew_install_if_missing jq
fi
if [[ "$NGINX_ENABLED" == "true" ]]; then
    if ! command -v certbot >/dev/null 2>&1; then
        _brew_install_if_missing certbot
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "${_Y}ERROR:${_R} curl not found."
    exit 1
fi

# --- 3. CLONE/PREPARE DIRECTORY ---
if [ -f "docker-compose.yml" ] || [ -d "coti-full-node" ]; then
    printf '%s\n' "${_Y}ERROR:${_R} Current directory is not clean for a fresh install."
    _w "  • docker-compose.yml present, or"
    _w "  • coti-full-node/ already exists"
    _w "Use an empty directory and run again."
    exit 1
fi

info "Cloning coti-full-node (main)..."
git clone -b main https://github.com/coti-io/coti-full-node.git
cd coti-full-node

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
# Network and image (chain defaults load from networks/\${NETWORK}.env).
# Bump DOCKER_FULL_NODE_IMAGE_VERSION (or set IMAGE=) to upgrade, then ./start_coti-full-node.sh
NETWORK=${NETWORK}
DOCKER_FULL_NODE_IMAGE_VERSION=${DOCKER_FULL_NODE_IMAGE_VERSION}

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
EOF

info "Writing node key..."
echo -n "$PK_CLEAN" > ./nodekey

if [[ "$FRPC_ENABLED" == "true" ]]; then
    info "Writing internal FRPC Nginx gateway config..."
    mkdir -p ./nginx
    cat <<EOF > ./nginx/frpc-gateway.conf

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream fullnode_8545 {
    server coti-full-node:8545  max_fails=3 fail_timeout=30s;
}

upstream fullnode_8546 {
    server coti-full-node:8546  max_fails=3 fail_timeout=30s;
}

upstream fullnode_6000 {
    server coti-full-node:6000  max_fails=3 fail_timeout=30s;
}

upstream operator_dashboard_8090 {
    server coti-operator-dashboard:8090  max_fails=3 fail_timeout=30s;
}

server {
    listen 8080;
    server_name _;

    location /ws {
        proxy_pass http://fullnode_8546/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
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

    location = /operator {
        return 301 /operator/;
    }

    location /operator/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://operator_dashboard_8090/;
    }
}
EOF

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
localIP = "nginx-frpc-gateway"
localPort = 8080
customDomains = ["$FRPC_CUSTOM_DOMAIN"]
EOF
    done
    unset _frpc_toml_pair _frpc_toml_file _frpc_server_addr
fi

if [[ "$NGINX_ENABLED" == "true" ]]; then
    info "Preparing Let's Encrypt HTTP-01 challenge..."
    mkdir -p ./nginx/certbot ./nginx/sites-enabled
    mkdir -p ./nginx/letsencrypt ./nginx/letsencrypt-work ./nginx/letsencrypt-logs

    # Project-local Certbot dirs (no /etc/letsencrypt on the host). Patch compose so Nginx mounts the same tree.
    info "Pointing docker-compose Nginx volume to ./nginx/letsencrypt (macOS installer)..."
    sed -i '' 's|- /etc/letsencrypt:/etc/letsencrypt:ro|- ./nginx/letsencrypt:/etc/letsencrypt:ro|' docker-compose.yml
    if ! grep -qF './nginx/letsencrypt:/etc/letsencrypt:ro' docker-compose.yml; then
        printf '%s\n' "${_Y}ERROR:${_R} Could not set Nginx bind mount to ./nginx/letsencrypt in docker-compose.yml."
        _w "Expected a line containing: - /etc/letsencrypt:/etc/letsencrypt:ro"
        exit 1
    fi

    info "Starting temporary Nginx for ACME..."
    $DC --profile setup up -d nginx-init

    CERTBOT_EXTRA=""
    if [[ "$CERTBOT_STAGING" == "true" ]]; then
        info "Requesting certificate for $FQDN (${_Y}Let's Encrypt staging${_R} — not browser-trusted)..."
        CERTBOT_EXTRA="--staging"
    else
        info "Requesting certificate for $FQDN..."
    fi
    _le_root="$(pwd)/nginx"
    certbot certonly --webroot -w "$(pwd)/nginx/certbot" -d "$FQDN" $CERTBOT_EXTRA \
        --config-dir "$_le_root/letsencrypt" \
        --work-dir "$_le_root/letsencrypt-work" \
        --logs-dir "$_le_root/letsencrypt-logs" \
        --register-unsafely-without-email --agree-tos --non-interactive
    unset _le_root

    info "Stopping temporary Nginx..."
    $DC --profile setup down

    info "Writing Nginx TLS proxy config..."
    cat <<EOF > ./nginx/sites-enabled/fullnode.conf

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream fullnode_8545 {
    server coti-full-node:8545  max_fails=3 fail_timeout=30s;
}

upstream fullnode_8546 {
    server coti-full-node:8546  max_fails=3 fail_timeout=30s;
}

upstream fullnode_6000 {
    server coti-full-node:6000  max_fails=3 fail_timeout=30s;
}

upstream operator_dashboard_8090 {
    server coti-operator-dashboard:8090  max_fails=3 fail_timeout=30s;
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
        proxy_pass http://fullnode_8546/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
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

    location = /operator {
        return 301 https://\$host/operator/;
    }

    location /operator/ {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://operator_dashboard_8090/;
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

info "Starting the full node stack..."
./start_coti-full-node.sh

_w ""
_div
ok "COTI full node is starting."
_w ""
if [[ "$NGINX_ENABLED" != "true" ]]; then
    _w "  • Mode: ${_B}no Nginx/SSL on this host${_R}"
    if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]] && [[ "$FRPC_ENABLED" == "true" ]]; then
        _w "  • COTI tunnel: JSON-RPC ${_B}https://${FRPC_CUSTOM_DOMAIN:-$FQDN}/rpc${_R}, WebSocket ${_U}https://${FRPC_CUSTOM_DOMAIN:-$FQDN}/ws${_R}, metrics ${_U}/metrics${_R}, operator ${_U}/operator/${_R}"
    else
        _w "  • RPC / WS: published on host ports 8545 / 8546 (see docker-compose)"
    fi
else
    _w "  • HTTPS: ${_B}https://$FQDN${_R} (RPC/WS: /rpc /ws; operator dashboard: /operator/)"
fi
if [[ "$FRPC_ENABLED" == "true" ]]; then
    _w "  • FRPC: ${_B}enabled${_R} — gateways $FRPS_SERVER_ADDR_1:$FRPS_SERVER_PORT, $FRPS_SERVER_ADDR_2:$FRPS_SERVER_PORT"
    _w "  • FRPC: host ${_B}${FRPC_CUSTOM_DOMAIN}${_R} — frpc → internal Nginx → ${_U}/rpc${_R}, ${_U}/ws${_R}, ${_U}/metrics${_R}, ${_U}/operator/${_R}"
    if [[ "${COTI_TUNNEL_INSTALL:-false}" == "true" ]]; then
        _w "  • Inbound firewall: ${_B}not required${_R} for 80/443/7400 from the internet (outbound FRP + local P2P)"
    fi
else
    _w "  • FRPC: ${_D}disabled${_R} (enable with ${_U}--with-frp${_R})"
fi
_w "  • Logs: ${_U}docker logs -f coti-$NETWORK-full-node${_R}"
if [[ "$NGINX_ENABLED" == "true" ]]; then
    _w "  • ${_B}Health check page${_R}: ${_U}https://$FQDN/operator/${_R} (or local ${_U}http://127.0.0.1:8090${_R})"
elif [[ "$FRPC_ENABLED" == "true" ]] && [[ -n "${FRPC_CUSTOM_DOMAIN:-}" ]]; then
    _w "  • ${_B}Health check page${_R}: ${_U}https://$FRPC_CUSTOM_DOMAIN/operator/${_R} (or local ${_U}http://127.0.0.1:8090${_R})"
else
    _w "  • ${_B}Health check page${_R} (this machine): ${_U}http://127.0.0.1:8090${_R}"
fi
_div
