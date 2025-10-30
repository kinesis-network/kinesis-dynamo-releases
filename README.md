## What is Dynamo

Kinesis Dynamo is an agent program that runs on a computing resource such as Home Computer, Corporate On-premise Server, Computing Node on a cloud service provider, and promotes it to a computing node in the Kinesis Network.

To learn more about Kinesis Network, please visit https://docs.kinesis.network/.

## About this repo

This repo is used for hosting public releases of Kinesis Dynamo.  Kinesis Dynamo is not *yet* open source software, but any bug report or feedback is more than welcome.  Please feel free to file an issue in this repo.

## How to install Dynamo

We provide a script to install required packages including Docker engine, download binaries,
and configure it to run as systemd services.

IMPORTANT: Before you continue, I encourage you to read the script; never trust someone
telling you to run random commands.

1. Download the bootstrap script

   ```shell
   curl -L -s \
     -H "Accept: application/octet-stream" \
     -o install_dynamo.sh \
     $(curl -L -s https://api.github.com/repos/kinesis-network/kinesis-dynamo-releases/releases/latest \
       | jq -r '.assets[] | select(.name | test(".sh$")) | .url'); chmod 755 install_dynamo.sh
   ```

2. Run the script

   ```shell
   PUBLIC_IP=global ./install_dynamo.sh
   ```

   where you can specify the following optional parameters.

   - `SERVICE_USER`: a service user to run dynamo processes (default: current user)
   - `PUBLIC_IP`: specify "global" to set up a global node (default: "")
   - `INSTALL_ROOT`: the root installation directory (default: /opt/dynamo)

3. Verify installation

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
