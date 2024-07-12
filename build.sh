#!/bin/bash

rm -rf .dfx

cp -R ./dfx.json ./dfx_temp.json

echo "==> build StakingPool..."

cat <<< $(jq '.canisters={
  "StakingPoolFactory": {
    "main": "./src/StakingPoolFactory.mo",
    "type": "motoko"
  },
  "StakingPool": {
    "main": "./src/StakingPool.mo",
    "type": "motoko"
  },
  "StakingFeeReceiver": {
    "main": "./src/StakingFeeReceiver.mo",
    "type": "motoko"
  },
  "StakingPoolIndex": {
    "main": "./src/StakingPoolIndex.mo",
    "type": "motoko"
  },
  "StakingPoolValidator": {
    "main": "./src/StakingPoolValidator.mo",
    "type": "motoko"
  }
}' dfx.json) > dfx.json

dfx start --background --clean

dfx canister create --all
dfx build --all
dfx stop
rm ./dfx.json
cp -R ./dfx_temp.json ./dfx.json
rm ./dfx_temp.json