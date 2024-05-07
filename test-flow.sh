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
  
  deploy_feeReceiver
  deploy_factory
  deploy_TestToken
  deploy_stakingPool
  
}

deploy_feeReceiver(){
      echo "==> install StakingFeeReceiver"
      dfx deploy --no-wallet --with-cycles=200000000000000000 --network=$env StakingFeeReceiver
}

deploy_factory(){
      echo "==> install StakingPoolFactory"
      feeReceiverCid=$(dfx canister id StakingFeeReceiver)
      echo "feeReceiverCid: $feeReceiverCid"
      echo "governanceCid: $governanceCid"
      dfx deploy --no-wallet --with-cycles=200000000000000000 --network=$env StakingPoolFactory --argument "(principal \"$feeReceiverCid\",opt principal \"$governanceCid\")"
      stakingPoolFactoryCid=$(dfx canister id StakingPoolFactory)
      echo "stakingPoolFactoryCid: $stakingPoolFactoryCid"
}

deploy_TestToken(){
      echo "==> install TestTokenA"
      minting_account="$(dfx identity get-principal)"
      dfx deploy TestTokenA --argument="( record {name = \"TestTokenA\"; symbol = \"TTA\"; decimals = 8; fee = 10; max_supply = 10000000000000000000000; initial_balances = vec {record {record {owner = principal \"$minting_account\";subaccount = null;};1000000000000000000}};min_burn_amount = 10_000;minting_account = null;advanced_settings = null; })"
}

deploy_stakingPool(){
      echo "==> deploy StakingPool"
      tokenCid=$(dfx canister id TestTokenA)
      echo "tokenCid: $tokenCid"
      createResult=$(dfx canister call StakingPoolFactory createStakingPool "(record {stakingTokenSymbol=\"TTA\"; startTime=1711972800; rewardTokenSymbol=\"TTA\"; stakingToken=record {address=\"$tokenCid\"; standard=\"ICRC2\"}; rewardToken=record {address=\"$tokenCid\"; standard=\"ICRC2\"}; rewardPerTime=5000000; name=\"TTA2TTA\"; stakingTokenFee=10; rewardTokenFee=10; stakingTokenDecimals=8; bonusEndTime=1717243200; rewardTokenDecimals=8})" | idl2json)
      echo "$createResult" | jq -r '.ok' | while read -r poolId; do
      echo "poolId ==> $poolId"
      # transfer reward token 
      dfx canister call TestTokenA icrc1_transfer "(record {to=record {owner=principal \"$poolId\"; subaccount=null}; fee=null; memo=null; from_subaccount=null; created_at_time=null; amount=100000000000000})"
      
      # user deposit
      dfx canister call TestTokenA icrc2_approve "(record{amount=1000000000000;created_at_time=null;expected_allowance=null;expires_at=null;fee=opt 10;from_subaccount=null;memo=null;spender=record {owner= principal \"$poolId\";subaccount=null;}})"
      dfx canister call $poolId depositFrom '(900_000_000)'
      sleep 10
      dfx canister call $poolId harvest
      sleep 15
      dfx canister call $poolId withdraw '(900_000_000)'

      #reward fee claim
      dfx canister call StakingFeeReceiver claim "(principal \"$poolId\")"

      done
}

deploy