set -e
source $HOME/.profile

read -r -p "Name of your Agoric node: " answer
echo Your node is $answer

echo "Installing Node js"
curl https://deb.nodesource.com/setup_12.x | sudo bash
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update
sudo apt upgrade -y
sudo apt install git -y
sudo apt install nodejs=12.* yarn build-essential jq -y


echo "Installing Go"
sudo rm -rf /usr/local/go
curl https://dl.google.com/go/go1.15.7.linux-amd64.tar.gz | sudo tar -C/usr/local -zxvf -
cat <<'EOF' >>$HOME/.profile
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GO111MODULE=on
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
EOF

source $HOME/.profile
echo "Installing Agoric SDK"
set +e
systemctl stop ag-chain-cosmos.service
rm -r /root/agoric-sdk
rm -r /root/.ag-chain-cosmos/
set -e
cd /root
git clone https://github.com/Agoric/agoric-sdk -b @agoric/sdk@2.15.1
cd agoric-sdk
yarn install
yarn build
(cd packages/cosmic-swingset && make)
ag-chain-cosmos version --long

echo "Configuring Agoric SDK"
set +e
rm /root/.ag-chain-cosmos/config/genesis.json
set -e
curl https://testnet.agoric.net/network-config > chain.json
# Set chain name to the correct value
chainName=`jq -r .chainName < chain.json`
# Confirm value: should be something like agorictest-N.
echo $chainName

ag-chain-cosmos init --chain-id $chainName $answer
curl https://testnet.agoric.net/genesis.json > $HOME/.ag-chain-cosmos/config/genesis.json 
# Reset the state of your validator.
ag-chain-cosmos unsafe-reset-all

# Set peers variable to the correct value
peers=$(jq '.peers | join(",")' < chain.json)
# Set seeds variable to the correct value.
seeds=$(jq '.seeds | join(",")' < chain.json)
# Confirm values, each should be something like "077c58e4b207d02bbbb1b68d6e7e1df08ce18a8a@178.62.245.23:26656,..."
echo $peers
echo $seeds

sed -i.bak 's/^log_level/# log_level/' $HOME/.ag-chain-cosmos/config/config.toml
# Replace the seeds and persistent_peers values
sed -i.bak -e "s/^seeds *=.*/seeds = $seeds/; s/^persistent_peers *=.*/persistent_peers = $peers/" $HOME/.ag-chain-cosmos/config/config.toml

echo "Setting up systemd task"

sudo tee <<EOF >/dev/null /etc/systemd/system/ag-chain-cosmos.service
[Unit]
Description=Agoric Cosmos daemon
After=network-online.target

[Service]
User=$USER
ExecStart=$HOME/go/bin/ag-chain-cosmos start --log_level=warn
Restart=on-failure
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable ag-chain-cosmos
sudo systemctl daemon-reload
sudo systemctl start ag-chain-cosmos


read -r -p "If you need to generate a key type in 'y' and hit enter. If you have already generated key and want to use it just hit enter." needkey
case $needkey in
     y)      
          ag-cosmos-helper keys add Key | tee /root/mnemonic
          read -r -p "Please write down your mnemonic phrase (above) and then press any button. The phrase will also be saved to /root/mnemonic file" confirm
          ;;     
esac

echo "Node syncing"
sed -i.bak 's/^log_level/# log_level/' $HOME/.ag-cosmos-helper/config/config.toml
while sleep 5; do
  sync_info=`ag-cosmos-helper status 2>&1 | jq .SyncInfo`
  echo "$sync_info"
  if test `echo "$sync_info" | jq -r .catching_up` == false; then
    echo "Caught up"
    break
  fi
done

echo "Setting validator"

# First, get the network config for the current network.
curl https://testnet.agoric.net/network-config > chain.json
# Set chain name to the correct value
chainName=`jq -r .chainName < chain.json`
# Confirm value: should be something like agorictest-N.
echo $chainName

valpub=$(ag-chain-cosmos tendermint show-validator)
echo $valpub

# First, get the network config for the current network.
curl https://testnet.agoric.net/network-config > chain.json
# Set chain name to the correct value
chainName=`jq -r .chainName < chain.json`
# Confirm value: should be something like agorictest-N.
echo $chainName

ag-cosmos-helper tx staking create-validator \
  --amount=50000000uagstake \
  --broadcast-mode=block \
  --pubkey=$valpub\
  --moniker=$answer\
  --commission-rate="0.10" \
  --commission-max-rate="0.20" \
  --commission-max-change-rate="0.01" \
  --min-self-delegation="1" \
  --from=Key \
  --chain-id=$chainName \
  --gas=auto \
  --gas-adjustment=1.4
