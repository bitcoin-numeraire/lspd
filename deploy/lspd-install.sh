#!/bin/bash

# Elevate privileges
if [ "$EUID" -ne 0 ]; then
sudo bash "$0" "$@"
exit
fi
# Redirect all outputs to a log file
exec > >(tee -a "/tmp/deployment.log") 2>&1
# fix locale if on debian 
if grep -q "Debian" /etc/os-release; then
    sed -i '/^# en_US.UTF-8 UTF-8/s/^# //' /etc/locale.gen
    locale-gen
    echo "export LC_ALL=en_US.UTF-8" >> /etc/bash.bashrc
    echo "export LANG=en_US.UTF-8" >> /etc/bash.bashrc

fi
source /etc/bash.bashrc
# create users
sudo adduser --disabled-password --gecos "" lightning
sudo adduser --disabled-password --gecos "" bitcoin
sudo adduser --disabled-password --gecos "" lspd

# Create a file to store the credentials
CREDENTIALS="/home/lspd/credentials.txt"
touch "$CREDENTIALS"
# Generate a random password for PostgreSQL users
LSPD_DB_PASSWORD=$(</dev/urandom tr -dc 'A-Za-z0-9' | head -c 20)
LIGHTNING_DB_PASSWORD=$(</dev/urandom tr -dc 'A-Za-z0-9' | head -c 20)
# Output the password to a file
echo "### PostgreSQL Credentials ###" >> "$CREDENTIALS"
echo "postgres lspd:" >> "$CREDENTIALS"
echo "username: lspd " >> "$CREDENTIALS"
echo "password: $LSPD_DB_PASSWORD" >> "$CREDENTIALS"
echo "postgres lightning:" >> "$CREDENTIALS"
echo "username: lightning" >> "$CREDENTIALS"
echo "password: $LIGHTNING_DB_PASSWORD" >> "$CREDENTIALS"

# Generic name if no name is provided (running locally)
if [ -z "$LSPName" ]; then
LSPName="lsp-$(</dev/urandom tr -dc 'A-Za-z0-9' | head -c 5)"
fi
# Install dependencies and required packages
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
sudo apt-get install -y git autoconf automake build-essential libtool libgmp-dev libsqlite3-dev python3 python3-pip net-tools zlib1g-dev postgresql postgresql-client-common postgresql-client postgresql postgresql-contrib libpq5  libsodium-dev gettext cargo protobuf-compiler libgmp3-dev  python-is-python3 libpq-dev jq

sudo pip3 install mako grpcio grpcio-tools

# Modify the pg_hba.conf file to set md5 password authentication for local connections
PG_VERSION=$(psql -V | awk '{print $3}' | awk -F"." '{print $1}')
sed -i 's/local   all             all                                     peer/local   all             all                                     md5/g' /etc/postgresql/$PG_VERSION/main/pg_hba.conf

# Create PostgreSQL users and databases
sudo -i -u postgres psql -c "CREATE ROLE lightning;"
sudo -i -u postgres psql -c "CREATE DATABASE lightning;"
sudo -i -u postgres psql -c "ALTER ROLE lightning WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '$LIGHTNING_DB_PASSWORD';"
sudo -i -u postgres psql -c "ALTER DATABASE lightning OWNER TO lightning;"

sudo -i -u postgres psql -c "CREATE ROLE lspd;"
sudo -i -u postgres psql -c "ALTER ROLE lspd WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS PASSWORD '$LSPD_DB_PASSWORD';"
sudo -i -u postgres psql -c "CREATE DATABASE lspd WITH TEMPLATE = template0 ENCODING = 'UTF8' LC_COLLATE = 'en_US.UTF-8' LC_CTYPE = 'en_US.UTF-8';"
sudo -i -u postgres psql -c "ALTER DATABASE lspd OWNER TO lspd;"

# Restart PostgreSQL to apply changes
service postgresql restart


# Create directories under /opt
sudo mkdir -p /opt/lightning /opt/lspd

# Install go
wget https://go.dev/dl/go1.20.6.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.20.6.linux-amd64.tar.gz
echo "export PATH=$PATH:/usr/local/go/bin" | sudo tee -a /etc/bash.bashrc
source /etc/bash.bashrc


# Install rust
curl https://sh.rustup.rs -sSf | sh -s -- -y

# Install bitcoin
wget https://bitcoincore.org/bin/bitcoin-core-25.0/bitcoin-25.0-x86_64-linux-gnu.tar.gz -O /opt/bitcoin.tar.gz
tar -xzf /opt/bitcoin.tar.gz -C /opt/
cd /opt/bitcoin-*/bin
chmod 710 /etc/bitcoin
sudo install -m 0755 -t /usr/local/bin *


cat <<EOL | sudo tee /etc/systemd/system/bitcoind.service
[Unit]
Description=Bitcoin daemon
After=network.target
[Service]
WorkingDirectory=/var/lib/bitcoind
ExecStart=bitcoind -pid=/run/bitcoind/bitcoind.pid -conf=/etc/bitcoin/bitcoin.conf 
PermissionsStartOnly=true
ExecStartPre=/bin/chgrp bitcoin /var/lib/bitcoind
Type=forking
PIDFile=/run/bitcoind/bitcoind.pid
Restart=on-failure
TimeoutStartSec=infinity
TimeoutStopSec=600
User=bitcoin
Group=bitcoin
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710
ConfigurationDirectory=bitcoin
StateDirectory=bitcoind
StateDirectoryMode=0710
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true
[Install]
WantedBy=multi-user.target
EOL

# cat to a bitcoin.conf file
RPCPASSWORD=$(</dev/urandom tr -dc 'A-Za-z0-9' | head -c 20)
echo "### Bitcoin Configuration ###" >> "$CREDENTIALS"
echo "rpcuser: cln" >> "$CREDENTIALS"
echo "rpcpassword: $RPCPASSWORD" >> "$CREDENTIALS"
sudo mkdir  /etc/bitcoin/
sudo touch /etc/bitcoin/bitcoin.conf
cat <<EOL | sudo tee /etc/bitcoin/bitcoin.conf
txindex=1
daemon=1
datadir=/var/lib/bitcoind
startupnotify='systemd-notify --ready' 
shutdownnotify='systemd-notify --stopping'
rpcuser=cln
rpcpassword=$RPCPASSWORD
minrelaytxfee=0.00000000
incrementalrelayfee=0.00000010
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
EOL

chown -R bitcoin:bitcoin /etc/bitcoin
chmod 755  /etc/bitcoin
sudo mkdir /home/lightning/.bitcoin/
sudo mkdir /root/.bitcoin/
sudo ln -s /etc/bitcoin/bitcoin.conf /home/lightning/.bitcoin/bitcoin.conf
sudo ln -s /etc/bitcoin/bitcoin.conf /root/.bitcoin/bitcoin.conf
###################################
######## Install lightning ########
###################################
sudo mkdir /home/lightning/.lightning/
sudo mkdir /etc/lightningd
#cat <<EOL | sudo tee /home/lightning/.lightning/config
cat <<EOL | sudo tee /etc/lightningd/lightningd.conf
developer
bitcoin-rpcuser=cln
bitcoin-rpcpassword=$RPCPASSWORD
bitcoin-rpcconnect=127.0.0.1
bitcoin-rpcport=8332
addr=:9735
bitcoin-retry-timeout=3600
alias="${LSPName}"
wallet=postgres://lightning:$LIGHTNING_DB_PASSWORD@localhost:5432/lightning
plugin=/home/lightning/.lightning/plugins/lspd_cln_plugin
lsp-listen=127.0.0.1:12312
grpc-port=12313
max-concurrent-htlcs=30
dev-allowdustreserve=true
log-file=/var/log/lightningd/lightningd.log
EOL
chmod 755 /etc/lightningd/
git clone https://github.com/ElementsProject/lightning.git /opt/lightning
cd /opt/lightning
git checkout v24.02.1
./configure
make
make install
cat <<EOL | sudo tee /etc/systemd/system/lightningd.service
[Unit]
Description=Lightning Network Provider Daemon (lightningd)
Wants=network-online.target
After=network.target
[Service]
ExecStart=/usr/local/bin/lightningd  --daemon --conf /etc/lightningd/lightningd.conf --pid-file=/run/lightningd/lightningd.pid
MemoryDenyWriteExecute=true
NoNewPrivileges=true
PrivateDevices=true
Type=forking
PrivateTmp=true
ProtectSystem=full
Restart=on-failure
User=lightning
Group=lightning
RuntimeDirectory=lightningd
ConfigurationDirectory=lightningd
LogsDirectory=lightningd
[Install]
WantedBy=multi-user.target
EOL

# Install lspd
git clone https://github.com/breez/lspd.git /opt/lspd
cd /opt/lspd
source /etc/bash.bashrc
export PATH=$PATH:/usr/local/go/bin
sudo env "PATH=$PATH" make release-all
sudo cp lspd /usr/local/bin/
sudo mkdir /home/lightning/.lightning/plugins
sudo cp lspd_cln_plugin /home/lightning/.lightning/plugins/

cat <<EOL | sudo tee /etc/systemd/system/lspd.service
[Unit]
Description=Lightning Service Daemon (lspd)
After=network.target
[Service]
User=lspd
EnvironmentFile=/home/lspd/.env
WorkingDirectory=/opt/lspd
ExecStart=/usr/local/bin/lspd
Restart=on-failure
RestartSec=5
EOL


sudo chown -R lightning:lightning /home/lightning/
sudo systemctl daemon-reload
sudo systemctl enable bitcoind.service
sudo systemctl enable lspd.service
sudo systemctl enable lightningd.service
sudo systemctl start bitcoind.service
sudo systemctl start lightningd.service

sleep 60
echo "### Lightning Credentials ###" >> "$CREDENTIALS"
sudo echo "cln hsm_secret backup:" >> "$CREDENTIALS"
sudo xxd /home/lightning/.lightning/bitcoin/hsm_secret >> "$CREDENTIALS"

# Post install
PUBKEY=$(sudo -u lightning lightning-cli getinfo | jq .id | cut -d "\"" -f 2)

LSPD_PRIVATE_KEY=$(lspd genkey | awk -F= '{print $2}' |  cut -d "\"" -f 2)
TOKEN=$(lspd genkey | awk -F= '{print $2}' |  cut -d "\"" -f 2)
EXTERNAL_IP=$(curl -s http://whatismyip.akamai.com/)
echo "### LSPD Credentials ###" >> "$CREDENTIALS"
echo "token: $TOKEN" >> "$CREDENTIALS"
echo "lspd_private_key: $LSPD_PRIVATE_KEY" >> "$CREDENTIALS"

cat <<EOL | sudo tee /home/lspd/.env

LISTEN_ADDRESS=0.0.0.0:8888
LSPD_PRIVATE_KEY="$LSPD_PRIVATE_KEY"
AWS_REGION="<REPLACE ME>"
AWS_ACCESS_KEY_ID="<REPLACE ME>"
AWS_SECRET_ACCESS_KEY="<REPLACE ME>"
DATABASE_URL="postgres://lspd:$LSPD_DB_PASSWORD@localhost/lspd"

OPENCHANNEL_NOTIFICATION_TO='["REPLACE ME <email@example.com>"]'
OPENCHANNEL_NOTIFICATION_CC='["REPLACE ME <test@example.com>"]'
OPENCHANNEL_NOTIFICATION_FROM="test@example.com"

CHANNELMISMATCH_NOTIFICATION_TO='["REPLACE ME <email@example.com>"]'
CHANNELMISMATCH_NOTIFICATION_CC='["REPLACE ME <email@example.com>"]'
CHANNELMISMATCH_NOTIFICATION_FROM="replaceme@example.com"

MEMPOOL_API_BASE_URL=https://mempool.space/api/v1/
MEMPOOL_PRIORITY=economy
NODES='[ { "name": "${LSPName}", "nodePubkey": "$PUBKEY", "lspdPrivateKey": "$LSPD_PRIVATE_KEY", "tokens": ["$TOKEN"], "host": "$EXTERNAL_IP:9735", "targetConf": "6", "minConfs": "6", "minHtlcMsat": "600", "baseFeeMsat": "1000", "feeRate": "0.000001", "timeLockDelta": "144", "channelFeePermyriad": "40", "channelMinimumFeeMsat": "2000000", "additionalChannelCapacity": "100000", "maxInactiveDuration": "3888000",  "cln": { "pluginAddress": "127.0.0.1:12312", "grpcAddress": "127.0.0.1:12313", "caCert": "/home/lightning/.lightning/mainnet/ca.pem", "clientCert": "/home/lightning/.lightning/mainnet/client.pem", "clientKey": "/home/lightning/.lightning/mainnet/client-key.pem" } } ]'

EOL
sudo systemctl start lspd.service
echo "Installation complete"
sudo chmod 400 /home/lspd/credentials.txt
echo "Make sure to backup the credentials.txt file that can be found at /home/lspd/credentials.txt"