import Nat "mo:base/Nat";
import Bool "mo:base/Bool";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Float "mo:base/Float";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";

module {

    public func natToBlob(x : Nat) : Blob {
        let arr : [Nat8] = fromNat(8, x);
        return Blob.fromArray(arr);
    };

    public func fromNat(len : Nat, n : Nat) : [Nat8] {
        let ith_byte = func(i : Nat) : Nat8 {
            assert (i < len);
            let shift : Nat = 8 * (len - 1 - i);
            Nat8.fromIntWrap(n / 2 ** shift);
        };
        return Array.tabulate<Nat8>(len, ith_byte);
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
        #deposit;
        #withdraw;
        #stake;
        #unstake;
        #harvest;
        #liquidate;
    };

    public type TransTokenType = {
        #stakeToken;
        #rewardToken;
    };

    public type LiquidationStatus = {
        #pending;
        #liquidation;
        #liquidated;
    };

    public type GlobalDataInfo = {
        valueOfStaking : Float;
        valueOfRewardsInProgress : Float;
        valueOfRewarded : Float;
        totalPools : Nat;
        totalStaker : Nat;
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
        transTokenType : TransTokenType;
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
        errMsg : Text;
        result : Text;
    };

    public type UserInfo = {
        var stakeTokenBalance : Nat;
        var rewardTokenBalance : Nat;
        var stakeAmount : Nat;
        var rewardDebt : Nat;
        var lastStakeTime : Nat;
        var lastRewardTime : Nat;
    };
    public type PublicUserInfo = {
        stakeTokenBalance : Nat;
        rewardTokenBalance : Nat;
        stakeAmount : Nat;
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
        name : Text;

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
        rewardPerTime : Nat;
        rewardFee : Nat;
        feeReceiverCid : Principal;

        creator : Principal;
        createTime : Nat;

        lastRewardTime : Nat;
        accPerShare : Nat;
        totalDeposit : Nat;
        rewardDebt : Nat;

        totalHarvest : Float;
        totalStaked : Float;
        totalUnstaked : Float;

        liquidationStatus : LiquidationStatus; //0:pending,1:liquidation,2:liquidated
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
        userIndexCid : Principal;
    };

    public type UpdateStakingPool = {
        startTime : Nat;
        bonusEndTime : Nat;
        rewardPerTime : Nat;
    };

    public type IStakingPool = actor {
        updateStakingPool : shared UpdateStakingPool -> async Result.Result<PublicStakingPoolInfo, Text>;
        stop : shared () -> async Result.Result<PublicStakingPoolInfo, Text>;

        unclaimdRewardFee : query () -> async Result.Result<Nat, Text>;
        withdrawRewardFee : shared () -> async Result.Result<Text, Text>;

        deposit : shared () -> async Result.Result<Text, Text>;
        depositFrom : shared (amount : Nat) -> async Result.Result<Text, Text>;
        stake : shared () -> async Result.Result<Nat, Text>;
        unstake : shared Nat -> async Result.Result<Nat, Text>;
        harvest : shared () -> async Result.Result<Nat, Text>;
        withdraw : shared (isStakeToken : Bool, amount : Nat) -> async Result.Result<Text, Text>;
        claim : shared () -> async Result.Result<Text, Text>;

        findUserInfo : query (offset : Nat, limit : Nat) -> async Result.Result<Page<(Principal, PublicUserInfo)>, Text>;
        getUserInfo : query Principal -> async Result.Result<PublicUserInfo, Text>;
        getPoolInfo : query () -> async Result.Result<PublicStakingPoolInfo, Text>;
        pendingReward : query Principal -> async Result.Result<Nat, Text>;
    };

    public type IStakingPoolFactory = actor {
        findStakingPoolPage : shared query (state : ?Nat, offset : Nat, limit : Nat) -> async Result.Result<Page<StakingPoolInfo>, Page<StakingPoolInfo>>;
        getStakingPool : shared query (poolCanisterId : Principal) -> async Result.Result<StakingPoolInfo, Text>;
    };

    public type IUserIndex = actor {
        updateUser : shared (userPrincipal : Principal, userInfo : PublicUserInfo) -> async Result.Result<Bool, Text>;
    };

    public type StakingFeeReceiver = {
        #claim : () -> (Principal);
        #getCycleInfo : () -> ();
        #getVersion : () -> ();
        #transfer : () -> (Token, Principal, Nat);
        #transferAll : () -> (Token, Principal);
    };

};
