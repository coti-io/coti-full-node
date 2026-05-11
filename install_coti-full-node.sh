#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# present the steps of the installer
echo "====================================================="
echo "       COTI Full Node Automated Installer"
echo "====================================================="
echo "1. OS validation"
echo "2. Validate required inputs (PK, FQDN as args)"
echo "3. Install host dependencies"
echo "4. Clone/prepare directory"
echo "5. Generate .env file"
echo "6. Configure private key (nodekey)"
echo "7. SSL and Nginx setup (skipped with --no-nginx, use --staging for Let's Encrypt staging)"
echo "8. Final launch"
echo "====================================================="
# Read from /dev/tty so prompts work when script is piped (curl | bash) - avoids consuming the script from stdin
read -p "Press Enter to continue or Ctrl+C to abort" < /dev/tty

# Load installer configuration (if present) so key constants can be customized without editing this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALLER_ENV_FILE="$SCRIPT_DIR/installer.env"
if [ -f "$INSTALLER_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$INSTALLER_ENV_FILE"
fi

# Default values (can be overridden in installer.env)
: "${DISK_SPACE_REQUIRED:=90}"      # GB

# present the requirements for the installer
echo "====================================================="
echo "       Requirements for the installer"
echo "====================================================="
echo "1. OS: Ubuntu 24.04 LTS (Certified by COTI)"
echo "2. Disk space: $DISK_SPACE_REQUIRED GB"
echo "3. Ports 80 and 443 must be available for Nginx (if nginx is not used, skip this requirement)"
echo "4. Port 7400 must be available"
echo "5. Firewall must not be blocking ports 80, 443 and 7400 (if ufw is not used, skip this requirement)"
echo "6. Iptables must not be blocking port 7400 (if iptables is not used, skip this requirement)"
echo "====================================================="
read -p "Press Enter to continue or Ctrl+C to abort" < /dev/tty

: "${DOCKER_FULL_NODE_IMAGE_VERSION:=1.2.0}"
: "${CLONE_BRANCH:=coti-testnet}"
: "${NETWORK:=testnet}"
: "${FRPC_ENABLED:=false}"
: "${FRPS_SERVER_ADDR:=gateway.fullnode.testnet.coti.io}"
: "${FRPS_SERVER_PORT:=7000}"
: "${FRPC_PROXY_NAME:=}"
: "${FRPC_CUSTOM_DOMAIN:=}"
: "${FRPC_AUTH_TOKEN:=}"
: "${COTI_FULL_NODE_RPC_LOCAL_PORT:=8545}"

# --- ROOT CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    echo
    echo "Example:"
    echo '  curl -sL https://fullnode.testnet.coti.io | sudo bash -s -- "0x..." "your.domain"'
    exit 1
fi

# Accept PK and FQDN as positional arguments
PK="$1"
FQDN="$2"

# Optional FRPC overrides via environment variables or flags.
for arg in "$@"; do
    case "$arg" in
        --no-nginx)
            NO_NGINX=true
            ;;
        --staging)
            CERTBOT_STAGING=true
            ;;
        --frpc-enabled=*)
            FRPC_ENABLED="${arg#*=}"
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
        --frps-server-port=*)
            FRPS_SERVER_PORT="${arg#*=}"
            ;;
    esac
done

echo "====================================================="
echo "       COTI Full Node Automated Installer"
echo "====================================================="

# --- 0. OS VALIDATION ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^24\.04 ]]; then
        echo "WARNING: This script only supports Ubuntu 24.04 LTS."
        echo "Detected: $PRETTY_NAME"
        read -p "Proceed at your own risk? (y/N): " PROCEED < /dev/tty
        if [[ ! "$PROCEED" =~ ^[yY] ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
fi

# --- 1. VALIDATE REQUIRED INPUTS (PK, FQDN as args) ---
if [ -z "$FQDN" ] || [ -z "$PK" ]; then
    echo "ERROR: PK and FQDN must be passed as arguments."
    echo "Example:"
    echo '  curl -sL https://fullnode.testnet.coti.io | sudo bash -s -- "0x..." "your.domain"'
    exit 1
fi

# Strip 0x prefix from PK for nodekey format
PK_CLEAN="${PK#0x}"

# Validate PK: must be exactly 64 hexadecimal characters (32 bytes)
if [[ ! "$PK_CLEAN" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: PK must be a 64-character hex string (32 bytes). Example: 0x1234...abcd"
    echo "Got ${#PK_CLEAN} characters."
    exit 1
fi

# Validate FQDN: hostname only (alphanumeric, hyphens, dots); prevents injection
if [[ ! "$FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || [ "${#FQDN}" -gt 253 ]; then
    echo "ERROR: FQDN must be a valid hostname (letters, numbers, hyphens, dots only; 1-253 chars)."
    echo "Example: node1.fullnode.testnet.coti.io"
    exit 1
fi

# Validate FRPC settings.
if [[ ! "$FRPC_ENABLED" =~ ^(true|false)$ ]]; then
    echo "ERROR: FRPC_ENABLED must be 'true' or 'false'."
    exit 1
fi

if [[ "$FRPC_ENABLED" == "true" ]] && [ -z "$FRPC_CUSTOM_DOMAIN" ]; then
    FRPC_CUSTOM_DOMAIN="$FQDN"
fi

if [ -z "$FRPC_PROXY_NAME" ]; then
    FRPC_PROXY_NAME="rpc-$FQDN"
fi

if [[ ! "$FRPS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$FRPS_SERVER_PORT" -lt 1 ] || [ "$FRPS_SERVER_PORT" -gt 65535 ]; then
    echo "ERROR: FRPS_SERVER_PORT must be a valid TCP port (1-65535)."
    exit 1
fi

if [[ ! "$COTI_FULL_NODE_RPC_LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$COTI_FULL_NODE_RPC_LOCAL_PORT" -lt 1 ] || [ "$COTI_FULL_NODE_RPC_LOCAL_PORT" -gt 65535 ]; then
    echo "ERROR: COTI_FULL_NODE_RPC_LOCAL_PORT must be a valid TCP port (1-65535)."
    exit 1
fi

# --- 1b. CHECK INSTALL DIRECTORY (writability + disk space) ---
INSTALL_DIR="$(pwd)"
if [ ! -w "$INSTALL_DIR" ]; then
    echo "ERROR: Cannot write to current directory ($INSTALL_DIR)."
    echo "Please run the installer from a writable directory (e.g. cd ~ or cd /mnt)."
    exit 1
fi

REQUIRED_KB=$((DISK_SPACE_REQUIRED * 1024 * 1024))
AVAIL_KB=$(df -P "$INSTALL_DIR" | awk 'NR==2 {print $4}')
if [ -z "$AVAIL_KB" ] || [ "$AVAIL_KB" -lt "$REQUIRED_KB" ]; then
    if [ -n "$AVAIL_KB" ]; then
        AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
        echo "ERROR: Insufficient disk space. $INSTALL_DIR is on a partition with only ${AVAIL_GB} GB free. Required: ${DISK_SPACE_REQUIRED} GB."
    else
        echo "ERROR: Unable to determine disk space for $INSTALL_DIR."
    fi
    echo "Please run the installer from a partition with enough space (e.g. cd /mnt)."
    exit 1
fi

# --- 1c. CHECK NGINX PORTS (80, 443) ARE AVAILABLE ---
if [[ "$NO_NGINX" != "true" ]]; then
    NGINX_PORTS="80 443"
    for port in $NGINX_PORTS; do
        if ss -tlnp 2>/dev/null | grep -qE ":$port\s"; then
            echo "ERROR: Port $port is already in use. Nginx requires ports 80 and 443 to be available."
            echo "Free the port or stop the conflicting service before running the installer."
            exit 1
        fi
    done
fi

# --- 1e. CHECK PORT 7400 IS AVAILABLE ---
if ss -tlnp 2>/dev/null | grep -qE "7400\s"; then
    echo "ERROR: Port 7400 is already in use. Please free the port before running the installer."
    exit 1
fi

# --- 1d/1f. CHECK FIREWALL/ IPTABLES RULES FOR REQUIRED PORTS ---
# Only perform ufw checks if ufw is installed and active.
if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi "Status: active"; then
        # For nginx mode, ensure there are no DENY/REJECT rules on 80 or 443.
        if [[ "$NO_NGINX" != "true" ]]; then
            if ufw status | awk '$1 == "80/tcp"  && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
                echo "ERROR: Firewall (ufw) is blocking port 80. Please unblock it before running the installer."
                exit 1
            fi
            if ufw status | awk '$1 == "443/tcp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
                echo "ERROR: Firewall (ufw) is blocking port 443. Please unblock it before running the installer."
                exit 1
            fi
        fi

        # For the node’s UDP/TCP port 7400, also ensure no DENY/REJECT rules.
        if ufw status | awk '$1 == "7400/udp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
            echo "ERROR: Firewall (ufw) is blocking port 7400/udp. Please unblock it before running the installer."
            exit 1
        fi
        if ufw status | awk '$1 == "7400/tcp" && ($2 == "DENY" || $2 == "REJECT") {found=1} END {exit !found}'; then
            echo "ERROR: Firewall (ufw) is blocking port 7400/tcp. Please unblock it before running the installer."
            exit 1
        fi
    fi
fi

# Check for iptables rules that explicitly block port 7400 (DROP or REJECT only).
# Do not flag chain jumps (e.g. ufw-user-input) or LOG rules, which do not block.
# exit !found: when blocking found, exit 0 so we run the error block; when not found, exit 1 so we continue
if command -v iptables >/dev/null 2>&1; then
    if iptables -L -n 2>/dev/null | awk '/dpt:7400/ && ($1 == "DROP" || $1 == "REJECT") {found=1} END {exit !found}'; then
        echo "ERROR: iptables appears to be blocking port 7400. Please unblock it before running the installer."
        exit 1
    fi
fi

# --- 2. INSTALL HOST DEPENDENCIES ---
echo "--> Installing necessary system dependencies (Docker, Certbot)..."
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
    echo "--> Docker already present, skipping docker.io (avoid containerd.io conflict)"
else
    PKGS="docker.io docker-compose $PKGS"
fi

if [[ "$NO_NGINX" != "true" ]]; then
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
    echo "ERROR: Current directory is not clean for a fresh install."
    echo "  - Found docker-compose.yml: you may be inside an existing clone."
    echo "  - Found coti-full-node/: a clone already exists here."
    echo "Please run the installer from an empty directory."
    exit 1
fi

echo "--> Cloning COTI full-node repository..."
git clone -b $CLONE_BRANCH https://github.com/coti-io/coti-full-node.git
cd coti-full-node

# --- 4. GENERATE .ENV FILE ---
echo "--> Generating environment variables..."
EXT_IP=$(curl -s https://api.ipify.org)

cat <<EOF > .env
FULLNODE_EXT_IP=$EXT_IP
FULLNODE_FQDN=$FQDN
FRPC_ENABLED=$FRPC_ENABLED
FRPS_SERVER_ADDR=$FRPS_SERVER_ADDR
FRPS_SERVER_PORT=$FRPS_SERVER_PORT
FRPC_PROXY_NAME=$FRPC_PROXY_NAME
FRPC_CUSTOM_DOMAIN=$FRPC_CUSTOM_DOMAIN
FRPC_AUTH_TOKEN=$FRPC_AUTH_TOKEN
COTI_FULL_NODE_RPC_LOCAL_PORT=$COTI_FULL_NODE_RPC_LOCAL_PORT
EOF

# --- 5. CONFIGURE PRIVATE KEY (NODEKEY) ---
echo "--> Setting up identity and node keys..."
# Ethereum/Geth based clients read the nodekey from a file
echo -n "$PK_CLEAN" > ./nodekey

# --- 5b. CONFIGURE FRPC (RPC RELAY ONLY) ---
FRPC_AUTH_BLOCK=""
if [ -n "$FRPC_AUTH_TOKEN" ]; then
    FRPC_AUTH_BLOCK=$(cat <<EOF
auth.method = "token"
auth.token = "$FRPC_AUTH_TOKEN"
EOF
)
fi

cat <<EOF > ./frpc.toml
serverAddr = "$FRPS_SERVER_ADDR"
serverPort = $FRPS_SERVER_PORT
$FRPC_AUTH_BLOCK

[[proxies]]
name = "$FRPC_PROXY_NAME"
type = "http"
localIP = "coti-testnet-full-node"
localPort = $COTI_FULL_NODE_RPC_LOCAL_PORT
customDomains = ["$FRPC_CUSTOM_DOMAIN"]
EOF

# --- 6-8. SSL AND NGINX SETUP (skipped with --no-nginx) ---
if [[ "$NO_NGINX" != "true" ]]; then
    echo "--> Preparing for Let's Encrypt challenge..."
    mkdir -p ./nginx/certbot ./nginx/sites-enabled

    # Start temporary nginx-init (profile: setup) - serves only port 80 for ACME challenge
    echo "--> Starting temporary Nginx to verify domain..."
    $DC --profile setup up -d nginx-init

    # --- 7. RUN CERTBOT ---
    CERTBOT_EXTRA=""
    if [[ "$CERTBOT_STAGING" == "true" ]]; then
        echo "--> Requesting SSL Certificate for $FQDN (Let's Encrypt STAGING - not trusted by browsers)..."
        CERTBOT_EXTRA="--staging"
    else
        echo "--> Requesting SSL Certificate for $FQDN..."
    fi
    certbot certonly --webroot -w "$(pwd)/nginx/certbot" -d "$FQDN" $CERTBOT_EXTRA --register-unsafely-without-email --agree-tos --non-interactive

    # Tear down temporary nginx-init so port 80 is free for main nginx
    echo "--> Tearing down temporary Nginx..."
    $DC --profile setup down

    # --- 8. APPLY FINAL NGINX CONFIG ---
    echo "--> Applying full HTTPS proxy configurations..."
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
# Use start_coti-full-node.sh (sources .env, pulls images, starts services)
echo "--> Starting up the full node stack..."
if [[ "$NO_NGINX" == "true" ]]; then
    ./start_coti-full-node.sh --no-nginx
else
    ./start_coti-full-node.sh
fi

echo "====================================================="
echo " SUCCESS! Your COTI full node is initializing."
if [[ "$NO_NGINX" == "true" ]]; then
    echo " Mode: node-only (no nginx/SSL). Access RPC/WS on ports 8545/8546."
else
    echo " FQDN: https://$FQDN"
fi
if [[ "$FRPC_ENABLED" == "true" ]]; then
    echo " FRPC RPC relay: enabled"
    echo " FRPS gateway: $FRPS_SERVER_ADDR:$FRPS_SERVER_PORT"
    echo " Public RPC domain: ${FRPC_CUSTOM_DOMAIN}"
else
    echo " FRPC RPC relay: disabled"
fi
echo " Use 'docker logs -f coti-$NETWORK-full-node' to view logs."
echo "====================================================="