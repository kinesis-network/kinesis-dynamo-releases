## What is Dynamo

Kinesis Dynamo is an agent program that runs on a computing resource such as Home Computer, Corporate On-premise Server, Computing Node on a cloud service provider, and promotes it to a computing node in the Kinesis Network.

To learn more about Kinesis Network, please visit https://docs.kinesis.network/.

## About this repo

This repo is used for hosting public releases of Kinesis Dynamo.  Kinesis Dynamo is not *yet* open source software, but any bug report or feedback is more than welcome.  Please feel free to file an issue in this repo.

## How to install Dynamo

We provide a script to install required packages including Docker engine, download binaries,
and configure it to run as systemd services.

Only Debian-based Linux distributions are supported.

IMPORTANT: Read [install.sh](install.sh) before you run it. Never run a command you haven't checked.

1. Run the install command

   Open **Add Servers** in the [Kinesis portal](https://portal.kinesis.network/signin) to get a
   command with your provision token, then run it on the server:

   ```shell
   curl -sSL https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/refs/heads/main/install.sh | env PROVISION_TOKEN=<your token> sh
   ```

   Keep the token secret: anyone who has it can register servers to your account.

   You can set these optional parameters in the same `env` list:

   - `RELEASE_VERSION`: the release tag to install (default: `latest`, the latest stable release)
   - `SERVICE_USER`: a service user to run dynamo processes (default: current user)
   - `INSTALL_ROOT`: the root installation directory (default: /opt/dynamo)

   To install a prerelease, use [install_prerelease.sh](install_prerelease.sh) and pin a tag from
   [Releases](https://github.com/kinesis-network/kinesis-dynamo-releases/releases):

   ```shell
   curl -sSL https://raw.githubusercontent.com/kinesis-network/kinesis-dynamo-releases/refs/heads/main/install_prerelease.sh | env PROVISION_TOKEN=<your token> RELEASE_VERSION=v0.4.28-beta2 sh
   ```

2. Verify installation

   Once installation is done, binaries and config files are placed in the root directory, and two services have started (dynamo and dynamo-admin).
   You can run `sudo systemctl status dynamo` and `sudo systemctl status dynamo-admin` to check the service status.

   To see your node’s address, run the following command:

   ```
   $ /opt/dynamo/noded --version --config=/opt/dynamo/config.json
   time=2025-10-30T19:30:15.695Z level=INFO msg="Loaded your wallet" addr=0x5626e3894cb35807fefdb84d4161d39d281bcab7 file=/opt/dynamo/id_ecdsa
   time=2025-10-30T19:30:15.695Z level=INFO msg="Loaded AppCacheFile" file=/opt/dynamo/app-cache.json
   time=2025-10-30T19:30:15.695Z level=INFO msg="Loaded a valid certificate" file=/opt/dynamo/backend.crt
   time=2025-10-30T19:30:15.695Z level=INFO msg="Loaded config" file=/opt/dynamo/config.json
   kinesis-dynamo v0.1.6 (git commit: f82a732eff9d0b4de2bd176ac945d0fc01d55266)
   Node (= your wallet) address: 0x5626E3894CB35807Fefdb84D4161D39d281bCAb7
   state:  NODE_STATE_DEFAULT
   ```
