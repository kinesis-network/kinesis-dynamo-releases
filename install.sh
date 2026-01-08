#!/bin/sh
# Dynamo bootstrap script: v0.1.10-beta1
echo "Setup script ran at $(date)"

# Detect WSL environment (check kernel version string set by WSL)
IS_WSL=false
if grep -q microsoft-standard-WSL2 /proc/version 2>/dev/null; then
  IS_WSL=true
  echo "WSL environment detected"
fi

sudo apt-get update -y
sudo apt-get install -y \
  jq curl gnupg lsb-release libarchive-tools \
  || { echo "failed to install dependent packages"; exit 1; }
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
fi
sudo systemctl enable docker
sudo systemctl start docker

# These placeholder strings will be replaced by Kinesis Cloud
# to pass this script to EC2 as user data
NODE_PROVISION_GUID=${NODE_PROVISION_GUID:-"INSTANCE_PROVISION_GUID_PLACEHOLDER"}

RELEASE_VERSION=${RELEASE_VERSION:-"latest"}
PUBLIC_IP=${PUBLIC_IP:-""}
INSTALL_ROOT=${INSTALL_ROOT:-"/opt/dynamo"}
SERVICE_USER=${SERVICE_USER:-"${USER}"}
CONFIG_PATH="$INSTALL_ROOT/config.json"

OS_ARCH=$(uname -m)
case "${OS_ARCH}" in
  x86_64)
    OS_ARCH=linux-amd64
    ;;
  aarch64 | arm64)
    OS_ARCH=linux-arm64
    ;;
  *)
    echo "Unsupported architecture: ${OS_ARCH}" >&2
    exit 1
    ;;
esac

sudo usermod -aG docker "$SERVICE_USER"
[ -d ${INSTALL_ROOT} ] || sudo mkdir -p "${INSTALL_ROOT}"
sudo chown -R ${SERVICE_USER}:${SERVICE_USER} "${INSTALL_ROOT}"
[ -d "${INSTALL_ROOT}/docker" ] || mkdir "${INSTALL_ROOT}/docker"

HAS_NVIDIA_GPU=false
if [ "$IS_WSL" = true ]; then
  /usr/lib/wsl/lib/nvidia-smi >/dev/null 2>&1 && HAS_NVIDIA_GPU=true
else
  lspci 2>/dev/null | grep -qi nvidia && HAS_NVIDIA_GPU=true
fi

if [ "$HAS_NVIDIA_GPU" = true ]; then
  echo "NVIDIA GPU detected. Installing NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update -y
  NVIDIA_CONTAINER_TOOLKIT_VERSION=$(apt-cache madison nvidia-container-toolkit | head -1 | awk '{print $3}')

  sudo apt-get install -y \
    nvidia-container-toolkit=$NVIDIA_CONTAINER_TOOLKIT_VERSION \
    nvidia-container-toolkit-base=$NVIDIA_CONTAINER_TOOLKIT_VERSION \
    libnvidia-container-tools=$NVIDIA_CONTAINER_TOOLKIT_VERSION \
    libnvidia-container1=$NVIDIA_CONTAINER_TOOLKIT_VERSION
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
else
  echo "No NVIDIA GPU found. Skipping NVIDIA toolkit install."
fi

REPO_BASE=https://api.github.com/repos/kinesis-network/kinesis-dynamo-releases
if [ "$RELEASE_VERSION" = "latest" ]; then
  RELEASE_URL="${REPO_BASE}/releases/latest"
else
  RELEASE_URL="${REPO_BASE}/releases/tags/$RELEASE_VERSION"
fi

echo "Fetching the release package from ${RELEASE_URL}"
ASSET_URL=$(curl -L -s ${RELEASE_URL} \
  | jq -r '.assets[] | select(.name | test("dynamo-.*-'${OS_ARCH}'\\.zip$")) | .url'
)
echo "Package URL: ${ASSET_URL}"

curl -L \
  -H "Accept: application/octet-stream" \
  -o /tmp/dynamo-release.zip \
  "$ASSET_URL"

if systemctl cat dynamo.service >/dev/null 2>&1; then
  sudo systemctl stop dynamo
fi
if systemctl cat dynamo-admin.service >/dev/null 2>&1; then
  sudo systemctl stop dynamo-admin
fi

bsdtar -xf /tmp/dynamo-release.zip --strip-components=1 -C "$INSTALL_ROOT"

try_fetch_aws() {
  md="http://169.254.169.254"
  token=""
  zone=""
  region=""

  token=$(curl -fsS --max-time 1 -X PUT "$md/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true

  if [ -n "$token" ]; then
    zone=$(curl -fsS --max-time 1 -H "X-aws-ec2-metadata-token: $token" \
      "$md/latest/meta-data/placement/availability-zone" 2>/dev/null) || return 1
  else
    zone=$(curl -fsS --max-time 1 \
      "$md/latest/meta-data/placement/availability-zone" 2>/dev/null) || return 1
  fi

  [ -z "$zone" ] && return 1

  # Region is AZ minus trailing letter (e.g., us-east-1a -> us-east-1)
  region="${zone%[a-z]}"

  [ -z "$region" ] && return 1

  printf '%s|%s\n' "$region" "$zone"
}

try_fetch_azure() {
  base="http://169.254.169.254/metadata/instance/compute"
  region=""
  zone=""

  region=$(curl -fsS --max-time 1 -H "Metadata: true" \
    "$base/location?api-version=2021-02-01&format=text" 2>/dev/null) || return 1

  [ -z "$region" ] && return 1

  # Zone can legitimately be empty; swallow errors and default to empty string
  zone=$(curl -fsS --max-time 1 -H "Metadata: true" \
    "$base/zone?api-version=2021-02-01&format=text" 2>/dev/null) || zone=""

  printf '%s|%s\n' "$region" "$zone"
}

REGION="unknown"
ZONE="unknown"
CSP="unknown"

FETCHERS="try_fetch_aws:aws try_fetch_azure:azure"

for entry in $FETCHERS; do
  func=${entry%%:*}
  name=${entry#*:}

  result=$($func 2>/dev/null) || continue
  case $result in
    *"|"*)
      REGION=${result%%|*}
      ZONE=${result#*|}
      ;;
    *)
      continue
      ;;
  esac

  if [ -n "$REGION" ]; then
    CSP=$name
    break
  fi
done

jq \
  --arg csp "$CSP" \
  --arg zone "$ZONE" \
  --arg region "$REGION" \
  --arg guid "$NODE_PROVISION_GUID" \
  --arg public_ip "${PUBLIC_IP}" \
  '.csp = $csp
  | .csp_zone = $zone
  | .csp_region = $region
  | .public_ip = $public_ip
  | .provision_guid = $guid' \
  "$CONFIG_PATH" > "$CONFIG_PATH.tmp"

mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

sed -i 's/User=ubuntu/User='${SERVICE_USER}'/' ${INSTALL_ROOT}/dynamo.service
sed -i 's/User=ubuntu/User='${SERVICE_USER}'/' ${INSTALL_ROOT}/dynamo-admin.service
sed -i 's|/opt/dynamo/|'${INSTALL_ROOT}/'|g' ${INSTALL_ROOT}/dynamo.service
sed -i 's|/opt/dynamo/|'${INSTALL_ROOT}/'|g' ${INSTALL_ROOT}/dynamo-admin.service
sed -i 's|/opt/dynamo/|'${INSTALL_ROOT}/'|g' ${CONFIG_PATH}

sudo cp ${INSTALL_ROOT}/dynamo.service /etc/systemd/system/
sudo cp ${INSTALL_ROOT}/dynamo-admin.service /etc/systemd/system/

sudo systemctl daemon-reload

sudo systemctl enable dynamo.service
sudo systemctl enable dynamo-admin.service

sudo systemctl start dynamo.service
sudo systemctl start dynamo-admin.service

output=$(${INSTALL_ROOT}/noded --version -config=${CONFIG_PATH} 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[FAIL] Dynamo installation failed"
fi

echo
echo "[OK] dynamo has been successfully installed."
echo
echo "Install directory: ${INSTALL_ROOT}"
echo "Config file: ${CONFIG_PATH}"
echo "Service user: ${SERVICE_USER}"
echo "${output}"
