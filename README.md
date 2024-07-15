# ICPSwap Staking Pool

The code is written in Motoko and developed in the DFINITY command-line execution [environment](https://internetcomputer.org/docs/current/references/cli-reference/dfx-parent). Please follow the documentation [here](https://internetcomputer.org/docs/current/developer-docs/setup/install/#installing-the-ic-sdk-1) to setup IC SDK environment and related command-line tools.  

## Introduction

**StakingPoolFactory**

This actor is mainly responsible for creating a staking pool. The admin can call the create function to create a valid staking pool. They can regularly compile operational information on all currently running staking pools, providing data support to everyone. They can also manage Canisters associated with Staking Pools, such as granting administrator or controller permissions.

**StakingPool**

This actor mainly includes the following two parts of business functions, which will be introduced separately below.

The first part is the staking logic of the staking pool: Users deposit staking tokens into their stake balance within the staking pool using the *deposit* or *depositFrom* functions. By calling the *stake* function, users convert their stake balance in the staking pool into actual staked quantities. The *harvest* function allows users to collect periodic reward tokens, transferring the reward token amount to the user's reward balance in the staking pool. Using the *unstake* function, users convert stake tokens from their actual stake in the staking pool into their stake balance and simultaneously harvest the current phase's reward tokens, transferring the reward token amount to the user's reward balance in the staking pool. The *withdraw* function enables users to withdraw tokens from their stake balance or reward balance to their caller account.

The second part is the management capabilities of the staking pool: The admin or controller can manage the operation of the staking pool in special circumstances using the *stop* and *updateStakingPool* functions. After the staking pool concludes its operation, the *liquidation* function settles the current pool, transferring the actual stake token amount of participating users to their stake balance and the allocated reward token amount up to the pool's end to their reward balance. Following the asset return to users, the *refundUserToken* function transfers the user's stake balance and reward balance out to their address. Once the refund process for user assets concludes, the *refundRewardToken* function transfers the remaining reward tokens to the *feeReceiverCid* address, completing the pool's processing cycle. At this point, the staking pool has terminated its operation entirely.

**StakingFeeReceiver**

This actor is responsible for the management of pledge fees and is mainly divided into two parts of business logic functions. All logic can only be called by addresses with Controller permissions. The first part is that the Controller can call the *claim* function to withdraw the pledge fees accumulated in the staking pool. The second part is that the Controller can call the *transfer* and *transferAll* functions to transfer the fee tokens to other addresses. The token standards supported by this actor include DIP20, DIP20-WICP, DIP20-XTC, EXT, ICRC1, ICRC2, ICRC3, and ICP.

**StakingPoolIndex**

This actor is responsible for gathering information about the staking pools in which users participate, enabling easier querying of all staking pools a user is involved in, thereby enhancing the user's interactive experience.

**StakingPoolFactoryValidator**

This actor is responsible for validating parameters and authorization during critical function calls in specific scenarios, ensuring the smooth operation of the staking pool.


## Local Testing

Run the `test-flow.sh` script to see how the whole process is working.

```bash
sh test-flow.sh
```

The script will deploy the following actors:

- StakingFeeReceiver
- StakingPoolFactory
- StakingPoolIndex
- StakingPoolFactoryValidator
- TestToken

After the deployment, the test script will run the following steps:

1. Deploy the canister of StakingFeeReceiver actor
2. Deploy the canister of StakingPoolFactory actor
3. Deploy the canister of StakingPoolIndex actor
4. Deploy the canister of StakingPoolFactoryValidator actor
5. Call the *createStakingPool* function from *StakingPoolFactory* canister to create a new staking pool
6. Call the *icrc1_transfer* function from *TestToken* canister to transfer reward tokens to the staking pool
7. Call the *icrc2_approve* function from *TestToken* canister to approve the staking pool to spend the stake tokens
8. Call the *depositFrom* function from *StakingPool* canister to deposit stake tokens to user stake balance of pool
9. Call the *stake* function from *StakingPool* canister to start the actual staking
10. Call the *harvest* function from *StakingPool* canister to harvest the reward tokens and transfer reward tokens to user reward balance of pool
11. Call the *unstake* function from *StakingPool* canister to unstake the stake tokens and transfer to user stake balance of pool
12. Call the *getUserInfo* function from *StakingPool* canister to print user balance
13. Call the *withdraw* function from *StakingPool* canister to withdraw the stake tokens from user stake balance of pool
14. Call the *withdraw* function from *StakingPool* canister to withdraw the reward tokens from user reward balance of pool
15. Call the *claim* function from *StakingFeeReceiver* canister to claim the reward fees from staking pool.