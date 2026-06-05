#!/bin/bash
# Kinesis Dynamo Bootstrap Script: v0.2.2-alpha4
set -e # Exit on error

echo "--- Kinesis Dynamo Setup started at $(date) ---"

# --- 1. Configuration & Placeholders ---
# These are replaced during deployment or set via environment
PROVISION_TOKEN=${PROVISION_TOKEN:-"TOKEN_PLACEHOLDER"}
UNIVERSE=${UNIVERSE:-"production"}
RELEASE_VERSION=${RELEASE_VERSION:-"latest"}
INSTALL_ROOT=${INSTALL_ROOT:-"/opt/dynamo"}
SERVICE_USER=${SERVICE_USER:-"$USER"}
CONFIG_PATH="$INSTALL_ROOT/config.json"
DYNAMO_SERVICES="dynamo.service dynamo-admin.service dynamo-ecc-enforcer.service dynamo-firewall.service"

# --- 2. Environment Detection ---
IS_WSL=false
if grep -q microsoft-standard-WSL2 /proc/version 2>/dev/null; then
    IS_WSL=true
    echo "[*] WSL2 environment detected"
fi

OS_ARCH=$(uname -m)
case "${OS_ARCH}" in
    x86_64) OS_ARCH=linux-amd64 ;;
    aarch64|arm64) OS_ARCH=linux-arm64 ;;
    *) echo "Unsupported architecture: ${OS_ARCH}"; exit 1 ;;
esac

echo "PROVISION_TOKEN=$PROVISION_TOKEN"
echo "UNIVERSE=$UNIVERSE"
echo "RELEASE_VERSION=$RELEASE_VERSION"
echo "INSTALL_ROOT=$INSTALL_ROOT"
echo "SERVICE_USER=$SERVICE_USER"
echo "CONFIG_PATH=$CONFIG_PATH"
echo "IS_WSL=$IS_WSL"
echo "OS_ARCH=$OS_ARCH"

# --- 3. Install Core Dependencies ---
echo "[*] Installing system dependencies..."
sudo apt-get update -y
sudo apt-get install -y jq curl gnupg lsb-release libarchive-tools pciutils

# Docker Setup
if ! command -v docker >/dev/null 2>&1; then
    echo "[*] Installing Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi

sudo systemctl enable --now docker
sudo usermod -aG docker "$SERVICE_USER"
sudo usermod -aG systemd-journal "$SERVICE_USER"

# --- 4. GPU Detection & Toolkit ---
HAS_NVIDIA_GPU=false
if [ "$IS_WSL" = true ]; then
    [ -f "/usr/lib/wsl/lib/nvidia-smi" ] && HAS_NVIDIA_GPU=true
else
    lspci | grep -qi nvidia && HAS_NVIDIA_GPU=true
fi

if [ "$HAS_NVIDIA_GPU" = true ]; then
    echo "[*] NVIDIA GPU detected. Setting up Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
fi

# --- 4.5 Stop existing services if they exist ---
echo "[*] Checking for existing services..."
for svc in $DYNAMO_SERVICES; do
    if systemctl is-active --quiet "$svc"; then
        echo "[*] Stopping $svc..."
        sudo systemctl stop "$svc"
    fi
done

# --- 5. Download & Extract Release ---
echo "[*] Downloading Kinesis Dynamo (${RELEASE_VERSION})..."
REPO="kinesis-network/kinesis-dynamo-releases"
if [ "$RELEASE_VERSION" = "latest" ]; then
    REL_DATA=$(curl -sL "https://api.github.com/repos/$REPO/releases/latest")
else
    REL_DATA=$(curl -sL "https://api.github.com/repos/$REPO/releases/tags/$RELEASE_VERSION")
fi

# Extract the specific zip URL for the detected architecture
ASSET_URL=$(echo "$REL_DATA" | jq -r --arg arch "$OS_ARCH" '.assets[] | select(.name | test("dynamo-.*-" + $arch + "\\.zip$")) | .url')
if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    echo "Failed to find a .zip asset for $OS_ARCH in release $RELEASE_VERSION"
    exit 1
fi
echo "[*] Found asset: $ASSET_URL"

sudo mkdir -p "$INSTALL_ROOT/mounts"
curl -sL -H "Accept: application/octet-stream" -o /tmp/dynamo.zip "$ASSET_URL"
sudo bsdtar -xvf /tmp/dynamo.zip -C "$INSTALL_ROOT"
sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_ROOT"
sudo rm /tmp/dynamo.zip

# --- 6. Cloud Metadata (Simplified) ---
echo "[*] Detecting Cloud Provider..."
CSP="manual"; REGION="unknown"; ZONE="unknown"
# Define common curl timeout settings
# --connect-timeout: max time to wait for connection
# -m, --max-time: max time for the whole operation
TIMEOUT_FLAGS="--connect-timeout 2 --max-time 3"
# AWS IMDSv2
if TOKEN=$(curl $TIMEOUT_FLAGS -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null); then
    ZONE=$(curl $TIMEOUT_FLAGS -fsS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/placement/availability-zone")
    REGION="${ZONE%[a-z]}"; CSP="aws"
# Azure
elif REGION=$(curl $TIMEOUT_FLAGS -fsS -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null); then
    CSP="azure"; ZONE=$(curl $TIMEOUT_FLAGS -fsS -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-02-01&format=text" 2>/dev/null || echo "1")
fi
echo "[*] Provider: $CSP ($REGION / $ZONE)"

# --- 7. Initialization & Config ---
echo "[*] Checking for existing wallet..."
SHOULD_INIT=true
if [ -f "$CONFIG_PATH" ]; then
    # Extract the wallet path from the existing config
    WALLET_FILE=$(sudo -u "$SERVICE_USER" jq -r '.key_manager.wallet_file // empty' "$CONFIG_PATH")
    if [ -n "$WALLET_FILE" ] && [ -f "$WALLET_FILE" ]; then
        echo "[*] Wallet detected at $WALLET_FILE. Skipping --init."
        SHOULD_INIT=false
    fi
fi

if [ "$SHOULD_INIT" = true ]; then
    echo "[*] Running gRPC initialization..."
    sudo -u "$SERVICE_USER" "${INSTALL_ROOT}/noded" --init="${PROVISION_TOKEN}" --root="${INSTALL_ROOT}" --universe="${UNIVERSE}"
fi

echo "[*] Patching configuration..."
# Ensure config exists before jq reads it
if [ ! -f "$CONFIG_PATH" ]; then
    echo "{}" | sudo -u "$SERVICE_USER" tee "$CONFIG_PATH" > /dev/null
fi

sudo -u "$SERVICE_USER" jq \
    --arg csp "$CSP" --arg reg "$REGION" --arg zone "$ZONE" \
    '. + {csp: $csp, csp_region: $reg, csp_zone: $zone}' \
    "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && sudo -u "$SERVICE_USER" mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

# --- 8. Systemd Integration ---
echo "[*] Configuring systemd services..."
for svc in $DYNAMO_SERVICES; do
    sudo sed -i "s|User=ubuntu|User=$SERVICE_USER|g" "$INSTALL_ROOT/$svc"
    sudo sed -i "s|/opt/dynamo/|$INSTALL_ROOT/|g" "$INSTALL_ROOT/$svc"
    sudo cp "$INSTALL_ROOT/$svc" /etc/systemd/system/
done

sudo systemctl daemon-reload

# Enable the firewall only when init marked this node for it (non-VPN nodes).
# The marker is written by `noded --init`; VPN nodes leave it absent.
FIREWALL_SERVICE="dynamo-firewall.service"
CORE_SERVICES=""
for svc in $DYNAMO_SERVICES; do
    [ "$svc" != "$FIREWALL_SERVICE" ] && CORE_SERVICES="$CORE_SERVICES $svc"
done

sudo systemctl enable --now $CORE_SERVICES

if [ -f "${INSTALL_ROOT}/firewall.enabled" ]; then
    echo "[*] Firewall enabled for this node."
    sudo systemctl enable --now "$FIREWALL_SERVICE"
else
    echo "[*] Firewall not enabled for this node; disabling service."
    sudo systemctl disable --now "$FIREWALL_SERVICE"
fi

# --- 9. Verification ---
output=$(sudo -u "$SERVICE_USER" "${INSTALL_ROOT}/noded" --version --config="$CONFIG_PATH" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[FAIL] Dynamo installation failed"
    exit 1
fi

echo
echo "[OK] dynamo has been successfully installed."
echo
echo "Install directory: ${INSTALL_ROOT}"
echo "Config file: ${CONFIG_PATH}"
echo "Service user: ${SERVICE_USER}"
echo "${output}"
