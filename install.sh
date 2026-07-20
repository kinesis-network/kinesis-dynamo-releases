#!/bin/sh
# Kinesis Dynamo Bootstrap Script: v0.2.11
set -e # Exit on error

echo "--- Kinesis Dynamo Setup started at $(date) ---"

# --- 1. Configuration ---
# Set via environment (PROVISION_TOKEN is exported by the bootstrap script).
PROVISION_TOKEN=${PROVISION_TOKEN:-""}
UNIVERSE=${UNIVERSE:-"production"}
RELEASE_VERSION=${RELEASE_VERSION:-"latest"}
INSTALL_ROOT=${INSTALL_ROOT:-"/opt/dynamo"}
SERVICE_USER=${SERVICE_USER:-"$USER"}
CONFIG_PATH="$INSTALL_ROOT/config.json"
# When true, `noded --init` is run with --test to generate test-specific config.
FOR_TEST=${FOR_TEST:-false}
DYNAMO_SERVICES="dynamo.service dynamo-admin.service dynamo-ecc-enforcer.service dynamo-firewall.service"
DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-""}
CONTAINERD_ROOT=${CONTAINERD_ROOT:-""}

# App-proxy provisioning (only used when PROVISION_TOKEN is a proxy token; for a
# normal node these are empty/unused). LB_POOL / PUBLIC_IP are passed through to
# `noded --init`, which pre-registers the proxy and writes a bundle to $PROXY_DIR.
LB_POOL=${LB_POOL:-""}
PUBLIC_IP=${PUBLIC_IP:-""}
PROXY_DIR="$INSTALL_ROOT/proxy"
NODE_PROXY_IMAGE=${NODE_PROXY_IMAGE:-"kinesisorg/node-proxy"}
NODE_PROXY_RAW_BASE=${NODE_PROXY_RAW_BASE:-"https://raw.githubusercontent.com/kinesis-network/node-proxy/refs/heads/main/deploy"}

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
echo "DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-<default>}"
echo "CONTAINERD_ROOT=${CONTAINERD_ROOT:-<default>}"

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

# --- 3.5. Optional: Relocate Docker data-root ---
# When DOCKER_DATA_ROOT is set, point Docker at it instead of the default
# /var/lib/docker. Two pieces:
#   1. /etc/docker/daemon.json gets data-root merged in via jq, so we
#      preserve any existing daemon settings (e.g. nvidia runtime).
#   2. If the data-root lives on a separately-mounted filesystem (cloud
#      ephemeral disks that mount late via cloud-init, attached NVMe,
#      etc.), drop a docker.service unit override with
#      RequiresMountsFor=<mount> so docker waits for the mount on every
#      boot. Without this, on reboots where the mount comes up late
#      docker starts first, finds its data-root path missing, and either
#      falls back to / or mkdirs into the empty mountpoint dir which
#      gets shadowed when the real filesystem mounts. The mount is
#      derived from `df` so the caller only needs to set
#      DOCKER_DATA_ROOT.
# Existing data under /var/lib/docker is NOT migrated automatically; if
# you care about preserving images/volumes, rsync them across before
# re-running.
if [ -n "$DOCKER_DATA_ROOT" ]; then
    echo "[*] Configuring Docker data-root: $DOCKER_DATA_ROOT"
    sudo mkdir -p "$DOCKER_DATA_ROOT" /etc/docker
    DAEMON_JSON="/etc/docker/daemon.json"
    if [ ! -s "$DAEMON_JSON" ]; then
        echo '{}' | sudo tee "$DAEMON_JSON" > /dev/null
    fi
    NEED_RESTART=false
    CURRENT_ROOT=$(sudo jq -r '."data-root" // ""' "$DAEMON_JSON")
    if [ "$CURRENT_ROOT" != "$DOCKER_DATA_ROOT" ]; then
        sudo jq --arg dr "$DOCKER_DATA_ROOT" '. + {"data-root": $dr}' "$DAEMON_JSON" \
            | sudo tee "$DAEMON_JSON.tmp" > /dev/null
        sudo mv "$DAEMON_JSON.tmp" "$DAEMON_JSON"
        echo "[*] Wrote data-root to $DAEMON_JSON"
        NEED_RESTART=true
    else
        echo "[*] Docker data-root already set to $DOCKER_DATA_ROOT in $DAEMON_JSON"
    fi
    DROPIN_DIR="/etc/systemd/system/docker.service.d"
    DROPIN_FILE="$DROPIN_DIR/wait-for-data-root.conf"
    DATA_ROOT_MOUNT=$(df --output=target "$DOCKER_DATA_ROOT" 2>/dev/null | tail -n1 | tr -d '[:space:]')
    if [ -n "$DATA_ROOT_MOUNT" ] && [ "$DATA_ROOT_MOUNT" != "/" ]; then
        DESIRED=$(printf '[Unit]\nRequiresMountsFor=%s\n' "$DATA_ROOT_MOUNT")
        if [ ! -f "$DROPIN_FILE" ] || [ "$(sudo cat "$DROPIN_FILE")" != "$DESIRED" ]; then
            echo "[*] data-root lives on $DATA_ROOT_MOUNT; ordering docker.service after the mount"
            sudo mkdir -p "$DROPIN_DIR"
            printf '%s\n' "$DESIRED" | sudo tee "$DROPIN_FILE" > /dev/null
            sudo systemctl daemon-reload
            NEED_RESTART=true
        else
            echo "[*] docker.service already waits for $DATA_ROOT_MOUNT (dropin up to date)"
        fi
    elif [ -f "$DROPIN_FILE" ]; then
        echo "[*] data-root is on /; removing stale $DROPIN_FILE"
        sudo rm -f "$DROPIN_FILE"
        sudo systemctl daemon-reload
        NEED_RESTART=true
    fi
    if [ "$NEED_RESTART" = true ]; then
        echo "[*] Restarting docker to apply data-root / unit changes..."
        sudo systemctl restart docker
    fi
fi

# --- 3.6. Optional: Relocate containerd root ---
# When CONTAINERD_ROOT is set, point the system containerd at it instead of
# the default /var/lib/containerd. dockerd talks to the system containerd
# over /run/containerd/containerd.sock, and depending on the engine version
# and snapshotter choice (e.g. features.containerd-snapshotter), image
# content can land under /var/lib/containerd rather than /var/lib/docker.
# Same shape as 3.5:
#   1. Edit /etc/containerd/config.toml so the top-level "root = ..." key
#      points at $CONTAINERD_ROOT. We delete any existing top-level root
#      line (commented or not) and insert a fresh one so we never end up
#      with a TOML duplicate key.
#   2. Drop a containerd.service unit override with RequiresMountsFor=<mount>
#      to fix the same reboot race as docker. Since docker.service has
#      Requires=containerd.service, this implicitly orders docker after
#      the mount too.
if [ -n "$CONTAINERD_ROOT" ]; then
    echo "[*] Configuring containerd root: $CONTAINERD_ROOT"
    sudo mkdir -p "$CONTAINERD_ROOT" /etc/containerd

    CONTAINERD_CONFIG="/etc/containerd/config.toml"
    if [ ! -s "$CONTAINERD_CONFIG" ]; then
        echo "[*] No existing $CONTAINERD_CONFIG; generating defaults"
        sudo containerd config default | sudo tee "$CONTAINERD_CONFIG" > /dev/null
    fi

    NEED_RESTART_CTRD=false
    CURRENT_CTRD_ROOT=$(grep -E '^root[[:space:]]*=' "$CONTAINERD_CONFIG" | head -n1 \
        | sed -E 's/^root[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
    if [ "$CURRENT_CTRD_ROOT" != "$CONTAINERD_ROOT" ]; then
        # Drop every top-level "root = " line (commented or not). The leading
        # ^ anchors to column 0 so we don't touch nested "root" subkeys inside
        # plugin tables, which are always indented.
        sudo sed -i -E '/^#?root[[:space:]]*=/d' "$CONTAINERD_CONFIG"
        if grep -qE '^version[[:space:]]*=' "$CONTAINERD_CONFIG"; then
            sudo sed -i -E "/^version[[:space:]]*=/a root = \"$CONTAINERD_ROOT\"" "$CONTAINERD_CONFIG"
        else
            sudo sed -i -E "1i root = \"$CONTAINERD_ROOT\"" "$CONTAINERD_CONFIG"
        fi
        echo "[*] Set root = \"$CONTAINERD_ROOT\" in $CONTAINERD_CONFIG"
        NEED_RESTART_CTRD=true
    else
        echo "[*] containerd root already set to $CONTAINERD_ROOT in $CONTAINERD_CONFIG"
    fi

    CTRD_DROPIN_DIR="/etc/systemd/system/containerd.service.d"
    CTRD_DROPIN_FILE="$CTRD_DROPIN_DIR/wait-for-root.conf"
    CTRD_MOUNT=$(df --output=target "$CONTAINERD_ROOT" 2>/dev/null | tail -n1 | tr -d '[:space:]')
    if [ -n "$CTRD_MOUNT" ] && [ "$CTRD_MOUNT" != "/" ]; then
        CTRD_DESIRED=$(printf '[Unit]\nRequiresMountsFor=%s\n' "$CTRD_MOUNT")
        if [ ! -f "$CTRD_DROPIN_FILE" ] || [ "$(sudo cat "$CTRD_DROPIN_FILE")" != "$CTRD_DESIRED" ]; then
            echo "[*] containerd root lives on $CTRD_MOUNT; ordering containerd.service after the mount"
            sudo mkdir -p "$CTRD_DROPIN_DIR"
            printf '%s\n' "$CTRD_DESIRED" | sudo tee "$CTRD_DROPIN_FILE" > /dev/null
            sudo systemctl daemon-reload
            NEED_RESTART_CTRD=true
        else
            echo "[*] containerd.service already waits for $CTRD_MOUNT (dropin up to date)"
        fi
    elif [ -f "$CTRD_DROPIN_FILE" ]; then
        echo "[*] containerd root is on /; removing stale $CTRD_DROPIN_FILE"
        sudo rm -f "$CTRD_DROPIN_FILE"
        sudo systemctl daemon-reload
        NEED_RESTART_CTRD=true
    fi

    if [ "$NEED_RESTART_CTRD" = true ]; then
        # docker.service Requires=containerd.service, so restarting containerd
        # alone leaves docker with a stale connection. Bounce both, in order.
        echo "[*] Restarting containerd (and docker, which depends on it)..."
        sudo systemctl restart containerd
        sudo systemctl restart docker
    fi
fi

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

# --- 6. Initialization & Config ---
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
    # --lb-pool / --public-ip are only meaningful for a proxy token; for a normal
    # node they are empty and init ignores them. For a proxy token, init also
    # pre-registers the proxy and writes the bundle to $PROXY_DIR.
    TEST_ARG=""
    [ "$FOR_TEST" = "true" ] && TEST_ARG="--test"
    sudo -u "$SERVICE_USER" "${INSTALL_ROOT}/noded" --init="${PROVISION_TOKEN}" --root="${INSTALL_ROOT}" --universe="${UNIVERSE}" --lb-pool="${LB_POOL}" --public-ip="${PUBLIC_IP}" $TEST_ARG

    # Detect the cloud provider and patch its metadata into the freshly
    # generated config. Done only on init so re-running install.sh on an
    # existing node respects its current values.
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

    if [ -f "$CONFIG_PATH" ]; then
        echo "[*] Patching configuration..."
        sudo -u "$SERVICE_USER" jq \
            --arg csp "$CSP" --arg reg "$REGION" --arg zone "$ZONE" \
            '. + {csp: $csp, csp_region: $reg, csp_zone: $zone}' \
            "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && sudo -u "$SERVICE_USER" mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    fi
fi

# Reconcile firewall_addr from the firewall marker on every run, leaving all
# other values in config.json untouched. This lets an existing node (which skips
# --init above and never had firewall_addr) pick up the correct setting. The
# marker is the single source of truth, written by `noded --init`; absent it the
# firewall is disabled. FIREWALL_ADDR must match firewall.DefaultSocketPath.
FIREWALL_MARKER="${INSTALL_ROOT}/firewall.enabled"
FIREWALL_ADDR="unix:///var/run/kinesis-dynamo/firewall.sock"
if [ -f "$CONFIG_PATH" ]; then
    if [ -f "$FIREWALL_MARKER" ]; then
        FW_FILTER='.plugins.docker.firewall_addr = $addr'
    else
        FW_FILTER='del(.plugins.docker.firewall_addr)'
    fi
    sudo -u "$SERVICE_USER" jq --arg addr "$FIREWALL_ADDR" "$FW_FILTER" \
        "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && sudo -u "$SERVICE_USER" mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
fi

# --- 7. Systemd Integration ---
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

# Enable the units, but don't start them yet: app-proxy nodes must bring up the
# node-proxy container first, and starting the dynamo service (which performs
# RegisterNode) is the last step for both node kinds.
sudo systemctl enable $CORE_SERVICES

# Enable the firewall only when init marked this node for it (non-VPN nodes; the
# marker is written by `noded --init`, absent for VPN nodes) AND this is not an
# app proxy. kinesis-firewall isn't integrated with the proxy service yet
# (frontend rules would need to sync with the firewall), so proxy nodes keep
# dynamo-firewall disabled even though they are non-VPN.
if [ -f "$FIREWALL_MARKER" ] && [ ! -f "$PROXY_DIR/proxy.env" ]; then
    ENABLE_FIREWALL=true
else
    ENABLE_FIREWALL=false
fi

if [ "$ENABLE_FIREWALL" = true ]; then
    echo "[*] Firewall enabled for this node."
    sudo systemctl enable "$FIREWALL_SERVICE"
else
    echo "[*] Firewall not enabled for this node; disabling service."
    sudo systemctl disable --now "$FIREWALL_SERVICE"
fi

# --- 7b. App proxy setup ---
# `noded --init` writes a bootstrap bundle ($PROXY_DIR/proxy.env) only when the
# provisioning token is a proxy token. When present, stand up the node-proxy
# container and activate the load balancer before starting the dynamo service.
if [ -f "$PROXY_DIR/proxy.env" ]; then
    echo "[*] App proxy detected; setting up node-proxy container..."
    # proxy.env: ADMIN_HOST, MGMT_USERNAME, MGMT_PASSWORD, REDIS_ADDRS,
    # REDIS_MASTER_NAME, REDIS_PASSWORD, CACERT_BASE64, CERT_FILE
    . "$PROXY_DIR/proxy.env"

    MOUNT_DIR="$PROXY_DIR/mount"
    CERTS_DIR="$PROXY_DIR/certs"
    # On-disk name for the shared wildcard. Matches what the Data Plane API writes
    # on rotation (it sanitizes dots to underscores), so a renewal overwrites it.
    WILDCARD_CERT_FILE="star_apps_kinesiscloud_com.pem"

    sudo mkdir -p "$CERTS_DIR" "$MOUNT_DIR" "$PROXY_DIR/general" "$PROXY_DIR/logs"
    sudo cp "$PROXY_DIR/$CERT_FILE" "$CERTS_DIR/$WILDCARD_CERT_FILE"

    # Download the node-proxy config files and fill the per-proxy placeholders
    # (DPA userlist password + admin-host ACL). dataplaneapi.yml is static.
    curl -fsSL "$NODE_PROXY_RAW_BASE/haproxy.cfg.template" -o /tmp/haproxy.cfg.template
    curl -fsSL "$NODE_PROXY_RAW_BASE/dataplaneapi.yml" -o /tmp/dataplaneapi.yml
    sed -e "s|@ADMIN_HOST@|${ADMIN_HOST}|g" \
        -e "s|@MGMT_USERNAME@|${MGMT_USERNAME}|g" \
        -e "s|@MGMT_PASSWORD@|${MGMT_PASSWORD}|g" \
        /tmp/haproxy.cfg.template | sudo tee "$MOUNT_DIR/haproxy.cfg" >/dev/null
    sudo cp /tmp/dataplaneapi.yml "$MOUNT_DIR/dataplaneapi.yml"

    echo "[*] Starting node-proxy container..."
    sudo docker rm -f node-proxy >/dev/null 2>&1 || true
    sudo docker run -d --name node-proxy \
        --network=host --restart=always --pull=always \
        -e ACME_SOCKET=/tmp/acme-sidecar.sock \
        -e REDIS_ADDRS="$REDIS_ADDRS" \
        -e REDIS_MASTER_NAME="$REDIS_MASTER_NAME" \
        -e REDIS_PASSWORD="$REDIS_PASSWORD" \
        -e CACERT_BASE64="$CACERT_BASE64" \
        -v "$CERTS_DIR:/etc/haproxy/certs" \
        -v "$MOUNT_DIR:/etc/haproxy/mount" \
        -v "$PROXY_DIR/general:/etc/haproxy/general" \
        -v "$PROXY_DIR/logs:/var/log/haproxy" \
        "$NODE_PROXY_IMAGE"

    echo "[*] Waiting for DataplaneAPI..."
    DPA_HEALTHY=false
    for _ in $(seq 1 30); do
        if curl -fsS -u "$MGMT_USERNAME:$MGMT_PASSWORD" \
             http://localhost:5555/v3/services/haproxy/runtime/info >/dev/null 2>&1; then
            DPA_HEALTHY=true
            break
        fi
        sleep 2
    done

    if [ "$DPA_HEALTHY" = true ]; then
        echo "[*] Post-registering app proxy (activating load balancer)..."
        sudo -u "$SERVICE_USER" "${INSTALL_ROOT}/noded" --postreg --config="$CONFIG_PATH"
    else
        echo "[WARN] DataplaneAPI did not become healthy; skipping activation (LB stays pending)."
    fi
fi

# Start the dynamo services last (-> RegisterNode).
echo "[*] Starting dynamo services..."
sudo systemctl start $CORE_SERVICES
if [ "$ENABLE_FIREWALL" = true ]; then
    sudo systemctl start "$FIREWALL_SERVICE"
fi

# --- 8. Verification ---
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
