#!/bin/bash

env=$1
governanceCid=$2

deploy(){

  if [ "$env" == "local" ]; then
        echo "local"
        dfx stop
        dfx start --background --clean
  fi

  if [ "$governanceCid" == "" ]; then
        governanceCid="$(dfx identity get-principal)"
  fi

  dfx deploy --no-wallet --with-cycles=200000000000000000 --network=$env StakingPoolFactory --argument "(opt principal \"$governanceCid\")"
}

deploy