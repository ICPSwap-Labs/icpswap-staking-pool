import Prim "mo:⛔";
import Nat "mo:base/Nat";
import Bool "mo:base/Bool";
import Text "mo:base/Text";
import Hash "mo:base/Hash";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Float "mo:base/Float";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";

module {

    public func equal(x : Nat, y : Nat) : Bool {
        return Nat.equal(x, y);
    };
    public func hash(x : Nat) : Hash.Hash {
        return Prim.natToNat32(x);
    };

    public func principalToBlob(p : Principal) : Blob {
        var arr : [Nat8] = Blob.toArray(Principal.toBlob(p));
        var defaultArr : [var Nat8] = Array.init<Nat8>(32, 0);
        defaultArr[0] := Nat8.fromNat(arr.size());
        var ind : Nat = 0;
        while (ind < arr.size() and ind < 32) {
            defaultArr[ind + 1] := arr[ind];
            ind := ind + 1;
        };
        return Blob.fromArray(Array.freeze(defaultArr));
    };

    public type Page<T> = {
        totalElements : Nat;
        content : [T];
        offset : Nat;
        limit : Nat;
    };

    public type CycleInfo = {
        balance : Nat;
        available : Nat;
    };

    public type Token = {
        address : Text;
        standard : Text;
    };
    public type Error = {
        #CommonError;
        #InternalError : Text;
        #UnsupportedToken : Text;
        #InsufficientFunds;
    };

    public type TransType = {
        #harvest;
        #stake;
        #unstake;
    };

    public type LedgerAmountState = {
        var harvest : Float;
        var staking : Float;
        var unStaking : Float;
    };

    public type LedgerAmountInfo = {
        harvest : Float;
        staking : Float;
        unStaking : Float;
    };

    public type GlobalDataState = {
        var stakingAmount : Float;
        var rewardAmount : Float;
    };
    public type GlobalDataInfo = {
        stakingAmount : Float;
        rewardAmount : Float;
    };
    public type TokenGlobalDataState = {
        var stakingTokenCanisterId : Text;
        var stakingTokenAmount : Nat;
        var stakingTokenPrice : Float;
        var stakingAmount : Float;
        var rewardTokenCanisterId : Text;
        var rewardTokenAmount : Nat;
        var rewardTokenPrice : Float;
        var rewardAmount : Float;
    };
    public type TokenGlobalDataInfo = {
        stakingTokenCanisterId : Text;
        stakingTokenAmount : Nat;
        stakingTokenPrice : Float;
        stakingAmount : Float;
        rewardTokenCanisterId : Text;
        rewardTokenAmount : Nat;
        rewardTokenPrice : Float;
        rewardAmount : Float;
    };

    public type Record = {
        timestamp : Nat;
        transType : TransType;
        from : Principal;
        to : Principal;
        amount : Nat;
        stakingToken : Text;
        stakingStandard : Text;
        stakingTokenDecimals : Nat;
        stakingTokenSymbol : Text;
        rewardToken : Text;
        rewardTokenDecimals : Nat;
        rewardTokenSymbol : Text;
        rewardStandard : Text;
    };

    public type UserInfo = {
        var amount : Nat;
        var rewardDebt : Nat;
        var lastStakeTime : Nat;
        var lastRewardTime : Nat;
    };
    public type PublicUserInfo = {
        amount : Nat;
        rewardDebt : Nat;
        pendingReward : Nat;
        lastStakeTime : Nat;
        lastRewardTime : Nat;
    };
    public type StakingPoolState = {
        var rewardToken : Token;
        var rewardTokenSymbol : Text;
        var rewardTokenFee : Nat;
        var rewardTokenDecimals : Nat;
        var stakingToken : Token;
        var stakingTokenSymbol : Text;
        var stakingTokenFee : Nat;
        var stakingTokenDecimals : Nat;

        var startTime : Nat;
        var bonusEndTime : Nat;
        var lastRewardTime : Nat;
        var rewardPerTime : Nat;
        var accPerShare : Nat;

        var creator : Principal;
        var createTime : Nat;

        var totalDeposit : Nat;
        var rewardDebt : Nat;
    };
    public type PublicStakingPoolInfo = {
        rewardToken : Token;
        rewardTokenSymbol : Text;
        rewardTokenDecimals : Nat;
        rewardTokenFee : Nat;
        stakingToken : Token;
        stakingTokenSymbol : Text;
        stakingTokenFee : Nat;
        stakingTokenDecimals : Nat;
        startTime : Nat;
        bonusEndTime : Nat;
        lastRewardTime : Nat;
        rewardPerTime : Nat;
        rewardFee : Nat;
        accPerShare : Nat;
        totalDeposit : Nat;
        rewardDebt : Nat;
        creator : Principal;
        createTime : Nat;
    };
    public type StakingPoolInfo = {
        canisterId : Principal;
        name : Text;
        createTime : Nat;
        startTime : Nat;
        bonusEndTime : Nat;
        stakingToken : Token;
        stakingTokenSymbol : Text;
        stakingTokenDecimals : Nat;
        stakingTokenFee : Nat;
        rewardToken : Token;
        rewardTokenSymbol : Text;
        rewardTokenDecimals : Nat;
        rewardTokenFee : Nat;
        rewardPerTime : Nat;
        creator : Principal;
    };

    public type InitRequest = {
        name : Text;
        rewardToken : Token;
        rewardTokenDecimals : Nat;
        rewardTokenSymbol : Text;
        rewardTokenFee : Nat;
        startTime : Nat;
        bonusEndTime : Nat;
        rewardPerTime : Nat;
        stakingToken : Token;
        stakingTokenDecimals : Nat;
        stakingTokenSymbol : Text;
        stakingTokenFee : Nat;
    };

    public type InitRequests = {
        name : Text;
        rewardToken : Token;
        rewardTokenDecimals : Nat;
        rewardTokenSymbol : Text;
        rewardTokenFee : Nat;
        startTime : Nat;
        bonusEndTime : Nat;
        rewardPerTime : Nat;
        stakingToken : Token;
        stakingTokenDecimals : Nat;
        stakingTokenSymbol : Text;
        stakingTokenFee : Nat;

        rewardFee : Nat;
        feeReceiverCid : Principal;
        creator : Principal;
        createTime : Nat;
    };

    public type UpdateStakingPool = {
        rewardToken : Token;
        rewardTokenFee : Nat;
        rewardTokenSymbol : Text;
        rewardTokenDecimals : Nat;
        stakingToken : Token;
        stakingTokenFee : Nat;
        stakingTokenSymbol : Text;
        stakingTokenDecimals : Nat;

        startTime : Nat;
        bonusEndTime : Nat;
        rewardPerTime : Nat;
    };

    public class TokenPrice(canister_id : ?Text) {
        let default_canister_id : Text = "arfra-7aaaa-aaaag-qb2aq-cai";
        let price_canister_id : Text = switch (canister_id) {
            case (?_canister_id) { _canister_id };
            case (null) { default_canister_id };
        };

        let tokenPrice : ITokenPrice = actor (price_canister_id) : ITokenPrice;

        public func getToken2ICPPrice(address : Text, standard : Text, tokenDecimals : Nat) : async Float {
            switch (await tokenPrice.getToken2ICPPrice(address, standard, tokenDecimals)) {
                case (#ok(price)) return price;
                case (#err(msg)) return 0.0000;
            };
        };
    };

    public type ITokenPrice = actor {
        getToken2ICPPrice : shared (address : Text, standard : Text, tokenDecimals : Nat) -> async Result.Result<Float, Text>;
    };

    public type IStakingPool = actor {
        updateStakingPool : shared UpdateStakingPool -> async Result.Result<Bool, Text>;
        stop : shared () -> async Result.Result<PublicStakingPoolInfo, Text>;
        setTime : shared (startTime : Nat, bonusEndTime : Nat) -> async Result.Result<PublicStakingPoolInfo, Text>;
        unclaimdRewardFee : query () -> async Result.Result<Nat, Text>;
        withdrawRewardFee : shared () -> async Result.Result<Text, Text>;

        stake : shared () -> async Result.Result<Text, Text>;
        stakeFrom : shared Nat -> async Result.Result<Text, Text>;
        harvest : shared () -> async Result.Result<Bool, Text>;
        unstake : shared Nat -> async Result.Result<Text, Text>;
        claim : shared () -> async Result.Result<Text, Text>;

        getUserInfo : query Principal -> async Result.Result<PublicUserInfo, Text>;
        getPoolInfo : query () -> async Result.Result<PublicStakingPoolInfo, Text>;
        pendingReward : query Principal -> async Result.Result<Nat, Text>;
    };

    public type StakingFeeReceiver = {
        #claim : () -> (Principal);
        #getCycleInfo : () -> ();
        #getVersion : () -> ();
        #transfer : () -> (Token, Principal, Nat);
        #transferAll : () -> (Token, Principal);
    };

};
