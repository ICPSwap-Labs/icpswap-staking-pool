import Prim "mo:⛔";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Blob "mo:base/Blob";
import Bool "mo:base/Bool";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Error "mo:base/Error";
import Float "mo:base/Float";
import Int64 "mo:base/Int64";
import Nat64 "mo:base/Nat64";
import Timer "mo:base/Timer";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";
import Result "mo:base/Result";
import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";

import SafeUint "mo:commons/math/SafeUint";
import CollectionUtils "mo:commons/utils/CollectionUtils";

import TokenFactory "mo:token-adapter/TokenFactory";

import Types "Types";

shared (initMsg) actor class StakingPool(params : Types.InitRequests) : async Types.IStakingPool = this {

    private stable var autoUnlockTimes = 200;
    private stable var arithmeticFactor = 1_000_000_000_000_000_000_00;
    private stable var totalRewardTokenTaxFee = 0;
    private stable var receivedRewardTokenTaxFee = 0;
    private stable var rewardTokenTax = params.rewardTokenTax;

    private stable var poolInfo : Types.StakingPoolState = {
        var rewardToken = params.rewardToken;
        var rewardTokenFee = params.rewardTokenFee;
        var rewardTokenSymbol = params.rewardTokenSymbol;
        var rewardTokenDecimals = params.rewardTokenDecimals;
        var stakingToken = params.stakingToken;
        var stakingTokenFee = params.stakingTokenFee;
        var stakingTokenSymbol = params.stakingTokenSymbol;
        var stakingTokenDecimals = params.stakingTokenDecimals;

        var rewardPerTime = params.rewardPerTime;

        var startTime = params.startTime;
        var bonusEndTime = params.bonusEndTime;

        var lastRewardTime = 0;
        var accPerShare = 0;
        var totalDeposit = 0;
        var rewardDebt = 0;
    };

    private stable var LedgerAmount = {
        var claim = 0.00;
        var staking = 0.00;
        var unStaking = 0.00;
        var stakingBalance = 0.00;
        var rewardBalance = 0.00;
    };

    private stable var userInfoList : [(Principal, Types.UserInfo)] = [];
    private var userInfoMap = HashMap.fromIter<Principal, Types.UserInfo>(userInfoList.vals(), 10, Principal.equal, Principal.hash);

    private stable var lockList : [(Principal, Nat)] = [];
    private var lockMap = HashMap.fromIter<Principal, Nat>(lockList.vals(), 0, Principal.equal, Principal.hash);

    private stable var _stakingRecords : [Types.Record] = [];
    private var _stakingRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);
    private stable var _rewardRecords : [Types.Record] = [];
    private var _rewardRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);

    //system func begin
    system func preupgrade() {
        userInfoList := Iter.toArray(userInfoMap.entries());
        lockList := Iter.toArray(lockMap.entries());
        _stakingRecords := Buffer.toArray(_stakingRecordBuffer);
        _rewardRecords := Buffer.toArray(_rewardRecordBuffer);
    };
    system func postupgrade() {
        userInfoList := [];
        lockList := [];
        for (record in _stakingRecords.vals()) {
            _stakingRecordBuffer.add(record);
        };
        for (record in _rewardRecords.vals()) {
            _rewardRecordBuffer.add(record);
        };
        _stakingRecords := [];
        _rewardRecords := [];
    };
    //system func end

    //admin shared func begin
    public shared (msg) func stop() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        poolInfo.bonusEndTime := _getTime();
        Timer.cancelTimer(updateTokenFeeId);
        Timer.cancelTimer(unlockId);
        return _getPoolInfo();
    };

    public shared (msg) func updateStakingPool(params : Types.UpdateStakingPool) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        poolInfo.rewardToken := params.rewardToken;
        poolInfo.rewardTokenFee := params.rewardTokenFee;
        poolInfo.rewardTokenSymbol := params.rewardTokenSymbol;
        poolInfo.rewardTokenDecimals := params.rewardTokenDecimals;
        poolInfo.stakingToken := params.stakingToken;
        poolInfo.stakingTokenFee := params.stakingTokenFee;
        poolInfo.stakingTokenSymbol := params.stakingTokenSymbol;
        poolInfo.stakingTokenDecimals := params.stakingTokenDecimals;

        poolInfo.startTime := params.startTime;
        poolInfo.bonusEndTime := params.bonusEndTime;
        poolInfo.rewardPerTime := params.rewardPerTime;
        return #ok(true);
    };

    public shared (msg) func clearLocks() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        var size = lockMap.size();
        lockMap := HashMap.HashMap<Principal, Nat>(0, Principal.equal, Principal.hash);
        return #ok(size);
    };

    public shared (msg) func setAutoUnlockTimes(n : Nat) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        if (n != 0) {
            autoUnlockTimes := n;
        };
        return #ok(autoUnlockTimes);
    };

    public shared (msg) func setTime(startTime : Nat, bonusEndTime : Nat) : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        poolInfo.startTime := startTime;
        poolInfo.bonusEndTime := bonusEndTime;
        return _getPoolInfo();
    };

    public shared (msg) func withdrawRemainingRewardToken(amount : Nat, to : Principal) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        let currentTime = _getTime();
        if (poolInfo.bonusEndTime > currentTime) {
            return #err("Staking pool is not over");
        };
        for ((userPrincipal, userInfo) in userInfoMap.entries()) {
            if (userInfo.amount > 0) {
                return #err("User Token have not been fully withdrawn");
            };
        };
        var token : Types.Token = {
            address = poolInfo.rewardToken.address;
            standard = poolInfo.rewardToken.standard;
        };
        let withdrawAmount = Nat.sub(amount, poolInfo.rewardTokenFee);
        return await pay(token, Principal.fromActor(this), null, to, null, withdrawAmount);
    };

    public shared func subaccountBalanceOf(owner : Principal) : async Result.Result<Nat, Text> {
        var subaccount : ?Blob = Option.make(Types.principalToBlob(owner));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(poolInfo.stakingToken.address, poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            return #ok(balance);
        } catch (e) {
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func refundSubaccountBalance(owner : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);
        var subaccount : ?Blob = Option.make(Types.principalToBlob(owner));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };
        var locked = lock(owner);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(poolInfo.stakingToken.address, poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                unLock(owner);
                return #err("The balance of subaccount is 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                unLock(owner);
                return #err("The balance of subaccount is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = owner; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    unLock(owner);
                    return #ok("Refund Successfully");
                };
                case (#Err(message)) {
                    unLock(owner);
                    return #err("RefundError:" #debug_show (message));
                };
            };
        } catch (e) {
            unLock(owner);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func refundUserStaking(owner : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);
        let currentTime = _getTime();
        if (poolInfo.bonusEndTime > currentTime) {
            return #err("Staking pool is not over");
        };
        var locked = lock(owner);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            switch (await _harvest(owner)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    unLock(owner);
                    return #err(err);
                };
            };

            var _userInfo : Types.UserInfo = _getUserInfo(owner);
            var withdrawAmount = _userInfo.amount;

            if (withdrawAmount == 0) {
                unLock(owner);
                return #err("The amount of withdrawal can’t be 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (withdrawAmount < fee) {
                unLock(owner);
                return #err("The amount of withdrawal is less than the staking token transfer fee");
            };
            switch (await pay(poolInfo.stakingToken, Principal.fromActor(this), null, owner, null, withdrawAmount - fee)) {
                case (#ok(amount)) {
                    var amount = withdrawAmount;
                    LedgerAmount.unStaking += Float.div(natToFloat(amount), Float.pow(10, natToFloat(poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    poolInfo.totalDeposit := Nat.sub(poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, poolInfo.accPerShare),
                        arithmeticFactor,
                    );
                    userInfoMap.put(owner, _userInfo);
                    let nowTime = _getTime();
                    save({
                        to = owner;
                        from = Principal.fromActor(this);
                        rewardStandard = poolInfo.rewardToken.standard;
                        rewardToken = poolInfo.rewardToken.address;
                        rewardTokenDecimals = poolInfo.rewardTokenDecimals;
                        rewardTokenSymbol = poolInfo.rewardTokenSymbol;
                        stakingStandard = poolInfo.rewardToken.standard;
                        stakingToken = poolInfo.stakingToken.address;
                        stakingTokenSymbol = poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #withdraw;
                    });
                    unLock(owner);
                    return #ok("Withdrew Successfully");
                };
                case (#err(code)) {
                    unLock(owner);
                    return #err("Withdraw::withdrawed error:" #debug_show (code));
                };
            };
        } catch (e) {
            unLock(owner);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public query (msg) func unclaimdRewardTokenTaxFee() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        return #ok(Nat.sub(totalRewardTokenTaxFee, receivedRewardTokenTaxFee));
    };

    public shared (msg) func claimTaxFee(to : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);
        var locked = lock(to);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(poolInfo.rewardToken.address, poolInfo.rewardToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = null;
            });
            if (not (balance > 0)) {
                unLock(to);
                return #err("The reward token balance of pool is 0");
            };
            var fee = poolInfo.rewardTokenFee;
            if (not (balance > fee)) {
                unLock(to);
                return #err("The reward token balance of pool is less than the reward token transfer fee");
            };
            let pending = Nat.sub(totalRewardTokenTaxFee, receivedRewardTokenTaxFee);
            if (not (balance > pending)) {
                unLock(to);
                return #err("The reward token balance of pool is less than the reward token tax fee");
            };
            if (not (pending > fee)) {
                unLock(to);
                return #err("The unclaimd reward token tax fee of pool is less than the reward token transfer fee");
            };

            var amount : Nat = Nat.sub(pending, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = to; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    unLock(to);
                    receivedRewardTokenTaxFee += pending;
                    return #ok("Claimed Successfully");
                };
                case (#Err(message)) {
                    unLock(to);
                    return #err("Claim::Claimed error:" #debug_show (message));
                };
            };
        } catch (e) {
            unLock(to);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };
    //admin shared func end

    //user shared func begin
    public shared (msg) func deposit() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let currentTime = _getTime();
        if (poolInfo.startTime > currentTime or poolInfo.bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(poolInfo.stakingToken.standard, "ICP") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (poolInfo.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };
        var locked = lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(poolInfo.stakingToken.address, poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                unLock(msg.caller);
                return #err("The amount of deposit can’t be 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                unLock(msg.caller);
                return #err("The amount of deposit is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);

            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    unLock(msg.caller);
                    return #err(err);
                };
            };
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = poolCanisterId; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    LedgerAmount.staking += Float.div(natToFloat(amount), Float.pow(10, natToFloat(poolInfo.stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, amount);
                    poolInfo.totalDeposit := Nat.add(poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, poolInfo.accPerShare),
                        arithmeticFactor,
                    );
                    userInfoMap.put(msg.caller, _userInfo);
                    var nowTime = _getTime();
                    save({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = poolInfo.rewardToken.standard;
                        rewardTokenSymbol = poolInfo.rewardTokenSymbol;
                        rewardTokenDecimals = poolInfo.rewardTokenDecimals;
                        rewardToken = poolInfo.rewardToken.address;
                        stakingStandard = poolInfo.stakingToken.standard;
                        stakingToken = poolInfo.stakingToken.address;
                        stakingTokenSymbol = poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #deposit;
                    });
                    unLock(msg.caller);
                    return #ok("Deposited Successfully");
                };
                case (#Err(message)) {
                    unLock(msg.caller);
                    return #err("Deposit::Deposited error:" #debug_show (message));
                };
            };
        } catch (e) {
            unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func depositFrom(amount : Nat) : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let currentTime = _getTime();
        if (poolInfo.startTime > currentTime or poolInfo.bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(poolInfo.stakingToken.standard, "ICP") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (poolInfo.stakingToken.standard));
        };
        var locked = lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {

            let tokenAdapter = TokenFactory.getAdapter(poolInfo.stakingToken.address, poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = msg.caller;
                subaccount = null;
            });
            if (not (balance > 0)) {
                unLock(msg.caller);
                return #err("The balance can’t be 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                unLock(msg.caller);
                return #err("The balance is less than the staking token transfer fee");
            };
            if (amount > balance) {
                unLock(msg.caller);
                return #err("The deposit amount is higher than the account balance");
            };
            var deposit_amount : Nat = Nat.sub(amount, fee);

            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    unLock(msg.caller);
                    return #err(err);
                };
            };
            var poolCanisterId = Principal.fromActor(this);
            switch (await tokenAdapter.transferFrom({ from = { owner = msg.caller; subaccount = null }; to = { owner = poolCanisterId; subaccount = null }; amount = deposit_amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    LedgerAmount.staking += Float.div(natToFloat(deposit_amount), Float.pow(10, natToFloat(poolInfo.stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, deposit_amount);
                    poolInfo.totalDeposit := Nat.add(poolInfo.totalDeposit, deposit_amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, poolInfo.accPerShare),
                        arithmeticFactor,
                    );
                    userInfoMap.put(msg.caller, _userInfo);
                    var nowTime = _getTime();
                    save({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = poolInfo.rewardToken.standard;
                        rewardTokenSymbol = poolInfo.rewardTokenSymbol;
                        rewardTokenDecimals = poolInfo.rewardTokenDecimals;
                        rewardToken = poolInfo.rewardToken.address;
                        stakingStandard = poolInfo.stakingToken.standard;
                        stakingToken = poolInfo.stakingToken.address;
                        stakingTokenSymbol = poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = poolInfo.stakingTokenDecimals;
                        amount = deposit_amount;
                        timestamp = nowTime;
                        transType = #depositFrom;
                    });
                    unLock(msg.caller);
                    return #ok("Deposited Successfully");
                };
                case (#Err(message)) {
                    unLock(msg.caller);
                    return #err("Deposit::Deposited error:" #debug_show (message));
                };
            };
        } catch (e) {
            unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func harvest() : async Result.Result<Nat, Text> {
        var locked = lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };
        try {
            let result = await _harvest(msg.caller);
            unLock(msg.caller);
            return result;
        } catch (e) {
            unLock(msg.caller);
            return #err("Harvest Exception: " #debug_show (Error.message(e)));
        };
    };

    public shared (msg) func withdraw(_amount : Nat) : async Result.Result<Text, Text> {
        var locked = lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    unLock(msg.caller);
                    return #err(err);
                };
            };

            var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
            var withdrawAmount = if (_amount > _userInfo.amount) {
                _userInfo.amount;
            } else {
                _amount;
            };
            if (withdrawAmount == 0) {
                unLock(msg.caller);
                return #err("The amount of withdrawal can’t be 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (withdrawAmount < fee) {
                unLock(msg.caller);
                return #err("The amount of withdrawal is less than the staking token transfer fee");
            };
            switch (await pay(poolInfo.stakingToken, Principal.fromActor(this), null, msg.caller, null, withdrawAmount - fee)) {
                case (#ok(amount)) {
                    var amount = withdrawAmount;
                    LedgerAmount.unStaking += Float.div(natToFloat(amount), Float.pow(10, natToFloat(poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    poolInfo.totalDeposit := Nat.sub(poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, poolInfo.accPerShare),
                        arithmeticFactor,
                    );
                    userInfoMap.put(msg.caller, _userInfo);
                    let nowTime = _getTime();
                    save({
                        to = msg.caller;
                        from = Principal.fromActor(this);
                        rewardStandard = poolInfo.rewardToken.standard;
                        rewardToken = poolInfo.rewardToken.address;
                        rewardTokenDecimals = poolInfo.rewardTokenDecimals;
                        rewardTokenSymbol = poolInfo.rewardTokenSymbol;
                        stakingStandard = poolInfo.rewardToken.standard;
                        stakingToken = poolInfo.stakingToken.address;
                        stakingTokenSymbol = poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #withdraw;
                    });
                    unLock(msg.caller);
                    return #ok("Withdrew Successfully");
                };
                case (#err(code)) {
                    unLock(msg.caller);
                    return #err("Withdraw::withdrawed error:" #debug_show (code));
                };
            };
        } catch (e) {
            unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func claim() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        if (Text.notEqual(poolInfo.stakingToken.standard, "ICP") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (poolInfo.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };
        var locked = lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(poolInfo.stakingToken.address, poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                unLock(msg.caller);
                return #err("The amount of claim is 0");
            };
            var fee = poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                unLock(msg.caller);
                return #err("The amount of claim is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = msg.caller; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    unLock(msg.caller);
                    return #ok("Claimed Successfully");
                };
                case (#Err(message)) {
                    unLock(msg.caller);
                    return #err("Claim::Claimed error:" #debug_show (message));
                };
            };
        } catch (e) {
            unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };
    //user shared func end

    //user query func begin
    public query func findAllUserInfo(offset : Nat, limit : Nat) : async Result.Result<Types.Page<(Principal, Types.PublicUserInfo)>, Text> {
        var buffer : Buffer.Buffer<(Principal, Types.PublicUserInfo)> = Buffer.Buffer<(Principal, Types.PublicUserInfo)>(userInfoMap.size());
        for ((userPrincipal, userInfo) in userInfoMap.entries()) {
            buffer.add((
                userPrincipal,
                {
                    amount = userInfo.amount;
                    rewardDebt = userInfo.rewardDebt;
                    pendingReward = _pendingReward(userPrincipal);
                },
            ));
        };

        var events = Buffer.toArray(buffer);
        return #ok({
            totalElements = events.size();
            content = CollectionUtils.arrayRange<(Principal, Types.PublicUserInfo)>(events, offset, limit);
            offset = offset;
            limit = limit;
        });
    };

    public query func getUserInfo(user : Principal) : async Result.Result<Types.PublicUserInfo, Text> {
        let __user = _getUserInfo(user);
        let pendingReward = _pendingReward(user);
        return #ok({
            amount = __user.amount;
            rewardDebt = __user.rewardDebt;
            pendingReward = pendingReward;
        });
    };

    public query func getAllLocks() : async Result.Result<[(Principal, Nat)], Text> {
        return #ok(Iter.toArray(lockMap.entries()));
    };

    public query func getPoolInfo() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        return _getPoolInfo();
    };

    public query func pendingReward(_user : Principal) : async Result.Result<Nat, Text> {
        return #ok(_pendingReward(_user));
    };

    public query func findStakingRecordPage(owner : ?Principal, offset : Nat, limit : Nat) : async Result.Result<Types.Page<Types.Record>, Text> {
        let size = _stakingRecordBuffer.size();
        if (size == 0) {
            return #ok({
                totalElements = 0;
                content = [];
                offset = offset;
                limit = limit;
            });
        };
        var buffer : Buffer.Buffer<(Types.Record)> = Buffer.Buffer<(Types.Record)>(200);
        var addBuffer = false;
        for (record in Buffer.toArray(_stakingRecordBuffer).vals()) {
            addBuffer := true;
            if (Option.isSome(owner)) {
                if (not Option.equal(owner, ?record.from, Principal.equal)) {
                    addBuffer := false;
                };
            };
            if (addBuffer) {
                buffer.add(record);
            };
        };
        let _stakingRecord = CollectionUtils.sort<Types.Record>(
            Buffer.toArray(buffer),
            func(x : Types.Record, y : Types.Record) : {
                #greater;
                #equal;
                #less;
            } {
                if (x.timestamp < y.timestamp) { #greater } else if (x.timestamp == y.timestamp) {
                    #equal;
                } else { #less };
            },
        );
        return #ok({
            totalElements = _stakingRecord.size();
            content = CollectionUtils.arrayRange<Types.Record>(_stakingRecord, offset, limit);
            offset = offset;
            limit = limit;
        });
    };

    public query func findRewardRecordPage(owner : ?Principal, offset : Nat, limit : Nat) : async Result.Result<Types.Page<Types.Record>, Text> {
        let size = _rewardRecordBuffer.size();
        if (size == 0) {
            return #ok({
                totalElements = 0;
                content = [];
                offset = offset;
                limit = limit;
            });
        };

        var buffer : Buffer.Buffer<(Types.Record)> = Buffer.Buffer<(Types.Record)>(200);
        var addBuffer = false;
        for (record in Buffer.toArray(_rewardRecordBuffer).vals()) {
            addBuffer := true;
            if (Option.isSome(owner)) {
                if (not Option.equal(owner, ?record.to, Principal.equal)) {
                    addBuffer := false;
                };
            };
            if (addBuffer) {
                buffer.add(record);
            };
        };
        let _rewardRecord = CollectionUtils.sort<Types.Record>(
            Buffer.toArray(buffer),
            func(x : Types.Record, y : Types.Record) : {
                #greater;
                #equal;
                #less;
            } {
                if (x.timestamp < y.timestamp) { #greater } else if (x.timestamp == y.timestamp) {
                    #equal;
                } else { #less };
            },
        );
        return #ok({
            totalElements = _rewardRecord.size();
            content = CollectionUtils.arrayRange<Types.Record>(_rewardRecord, offset, limit);
            offset = offset;
            limit = limit;
        });
    };
    //user query func end

    //private func begin
    private func _getPoolInfo() : Result.Result<Types.PublicStakingPoolInfo, Text> {
        return #ok({
            rewardToken = poolInfo.rewardToken;
            rewardTokenSymbol = poolInfo.rewardTokenSymbol;
            rewardTokenDecimals = poolInfo.rewardTokenDecimals;
            rewardTokenFee = poolInfo.rewardTokenFee;
            stakingToken = poolInfo.stakingToken;
            stakingTokenSymbol = poolInfo.stakingTokenSymbol;
            stakingTokenDecimals = poolInfo.stakingTokenDecimals;
            stakingTokenFee = poolInfo.stakingTokenFee;

            startTime = poolInfo.startTime;
            bonusEndTime = poolInfo.bonusEndTime;
            lastRewardTime = poolInfo.lastRewardTime;
            rewardPerTime = poolInfo.rewardPerTime;
            rewardTokenTax = rewardTokenTax;
            accPerShare = poolInfo.accPerShare;

            totalDeposit = poolInfo.totalDeposit;
            rewardDebt = poolInfo.rewardDebt;
        });
    };

    private func unlock() : async () {
        let nowTimes = _getTime();
        for ((userPrincipal, lockTime) in lockMap.entries()) {
            if ((SafeUint.Uint256(nowTimes).sub(SafeUint.Uint256(lockTime)).val()) > autoUnlockTimes) {
                unLock(userPrincipal);
            };
        };
    };

    private func lock(caller : Principal) : Bool {
        switch (lockMap.get(caller)) {
            case (null) {
                var nowTime = _getTime();
                lockMap.put(caller, nowTime);
                return true;
            };
            case (?lockUser) {
                return false;
            };
        };
    };

    private func unLock(caller : Principal) : () {
        lockMap.delete(caller);
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func updateTokenFee() : async () {
        let stakingTokenAdapter = TokenFactory.getAdapter(
            poolInfo.stakingToken.address,
            poolInfo.stakingToken.standard,
        );
        poolInfo.stakingTokenFee := await stakingTokenAdapter.fee();
        poolInfo.stakingTokenDecimals := Nat8.toNat(await stakingTokenAdapter.decimals());
        poolInfo.stakingTokenSymbol := await stakingTokenAdapter.symbol();

        let rewardTokenAdapter = TokenFactory.getAdapter(
            poolInfo.rewardToken.address,
            poolInfo.rewardToken.standard,
        );
        poolInfo.rewardTokenFee := await rewardTokenAdapter.fee();
        poolInfo.rewardTokenDecimals := Nat8.toNat(await rewardTokenAdapter.decimals());
        poolInfo.rewardTokenSymbol := await rewardTokenAdapter.symbol();
    };

    private func _getUserInfo(user : Principal) : Types.UserInfo {
        switch (userInfoMap.get(user)) {
            case (?_userInfo) {
                _userInfo;
            };
            case (_) {
                {
                    var amount = 0;
                    var rewardDebt = 0;
                    var lastRewardTime = 0;
                };
            };
        };
    };

    private func pay(token : Types.Token, payer : Principal, payerSubAccount : ?Blob, recipient : Principal, recipientSubAccount : ?Blob, value : Nat) : async Result.Result<Nat, Text> {
        let tokenAdapter = TokenFactory.getAdapter(token.address, token.standard);
        var params = {
            from = { owner = payer; subaccount = payerSubAccount };
            from_subaccount = payerSubAccount;
            to = { owner = recipient; subaccount = recipientSubAccount };
            fee = null;
            amount = value;
            memo = null;
            created_at_time = null;
        };
        if (Principal.toText(payer) == Principal.toText(Principal.fromActor(this))) {
            switch (await tokenAdapter.transfer(params)) {
                case (#Ok(index)) { return #ok(value) };
                case (#Err(code)) { return #err(debug_show (code)) };
            };
        } else {
            switch (await tokenAdapter.transferFrom(params)) {
                case (#Ok(index)) { return #ok(value) };
                case (#Err(code)) { return #err(debug_show (code)) };
            };
        };
    };

    private func getRewardInterval(lastRewardTime : Nat, nowTime : Nat) : Nat {
        if (lastRewardTime < poolInfo.bonusEndTime) {
            if (nowTime <= poolInfo.bonusEndTime) {
                return Nat.sub(nowTime, lastRewardTime);
            } else {
                return Nat.sub(poolInfo.bonusEndTime, lastRewardTime);
            };
        } else {
            return 0;
        };
    };

    private func updatePool() : async () {
        var nowTime = _getTime();
        if (nowTime <= poolInfo.lastRewardTime) { return };
        if (poolInfo.totalDeposit == 0) {
            poolInfo.lastRewardTime := nowTime;
            return;
        };
        var rewardInterval : Nat = getRewardInterval(poolInfo.lastRewardTime, nowTime);
        var reward : Nat = Nat.mul(rewardInterval, poolInfo.rewardPerTime);
        poolInfo.accPerShare := Nat.add(poolInfo.accPerShare, Nat.div(Nat.mul(reward, arithmeticFactor), poolInfo.totalDeposit));
        poolInfo.lastRewardTime := nowTime;
    };

    private func _pendingReward(user : Principal) : Nat {
        var nowTime = _getTime();
        Debug.print("nowTime: " # debug_show (nowTime));
        Debug.print("poolInfo.lastRewardTime: " # debug_show (poolInfo.lastRewardTime));
        Debug.print("poolInfo.totalDeposit: " # debug_show (poolInfo.totalDeposit));
        Debug.print("poolInfo.accPerShare: " # debug_show (poolInfo.accPerShare));
        var _userInfo : Types.UserInfo = _getUserInfo(user);
        Debug.print("_userInfo: " # debug_show (_userInfo));
        if (nowTime > poolInfo.lastRewardTime and poolInfo.totalDeposit != 0) {
            var rewardInterval : Nat = getRewardInterval(poolInfo.lastRewardTime, nowTime);
            Debug.print("rewardInterval: " # debug_show (rewardInterval));
            var reward : Nat = Nat.mul(rewardInterval, poolInfo.rewardPerTime);
            Debug.print("reward: " # debug_show (reward));
            poolInfo.accPerShare := Nat.add(poolInfo.accPerShare, Nat.div(Nat.mul(reward, arithmeticFactor), poolInfo.totalDeposit));
            Debug.print("poolInfo.accPerShare2: " # debug_show (poolInfo.accPerShare));
        };
        //(deposit_amount * accPerShare) / arithmeticFactor - rewardDebt
        var rewardAmount = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, poolInfo.accPerShare), arithmeticFactor), _userInfo.rewardDebt);
        let rewardTokenTaxFee : Nat = Nat.div(Nat.mul(rewardAmount, rewardTokenTax), 100);
        if (rewardTokenTaxFee > 0) {
            rewardAmount := rewardAmount - rewardTokenTaxFee;
        };
        return rewardAmount;
    };

    private func natToFloat(amount : Nat) : Float {
        Float.fromInt(amount);
    };

    private func _harvest(caller : Principal) : async Result.Result<Nat, Text> {
        await updatePool();
        var _userInfo : Types.UserInfo = _getUserInfo(caller);
        Debug.print("_harvest: userinfo = " #debug_show (_userInfo));
        var pending : Nat = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, poolInfo.accPerShare), arithmeticFactor), _userInfo.rewardDebt);
        Debug.print("_harvest: pending = " #debug_show (pending));
        if (pending == 0 or pending < poolInfo.rewardTokenFee) {
            return #ok(0);
        };
        var rewardAmount = pending;
        let rewardTokenTaxFee : Nat = Nat.div(Nat.mul(rewardAmount, rewardTokenTax), 100);
        if (rewardTokenTaxFee > 0) {
            totalRewardTokenTaxFee += rewardTokenTaxFee;
            rewardAmount := rewardAmount - rewardTokenTaxFee;
        };

        if (rewardAmount < poolInfo.rewardTokenFee) {
            totalRewardTokenTaxFee -= rewardTokenTaxFee;
            return #ok(0);
        };
        switch (await pay(poolInfo.rewardToken, Principal.fromActor(this), null, caller, null, rewardAmount - poolInfo.rewardTokenFee)) {
            case (#ok(amount)) {
                LedgerAmount.claim += Float.div(natToFloat(amount), Float.pow(10, natToFloat(poolInfo.rewardTokenDecimals)));
                poolInfo.rewardDebt := poolInfo.rewardDebt + pending;
                _userInfo.rewardDebt := Nat.div(Nat.mul(_userInfo.amount, poolInfo.accPerShare), arithmeticFactor);
                userInfoMap.put(caller, _userInfo);
                var nowTime = _getTime();
                save({
                    from = Principal.fromActor(this);
                    to = caller;
                    rewardStandard = poolInfo.rewardToken.standard;
                    rewardToken = poolInfo.rewardToken.address;
                    rewardTokenSymbol = poolInfo.rewardTokenSymbol;
                    rewardTokenDecimals = poolInfo.rewardTokenDecimals;
                    stakingStandard = poolInfo.stakingToken.standard;
                    stakingToken = poolInfo.stakingToken.address;
                    stakingTokenDecimals = poolInfo.stakingTokenDecimals;
                    stakingTokenSymbol = poolInfo.stakingTokenSymbol;
                    amount = rewardAmount;
                    timestamp = nowTime;
                    transType = #claim;
                });
                return #ok(amount);
            };
            case (#err(code)) {
                Debug.print("_harvest error = " #debug_show (code));
                return #err("Harvest error:" #debug_show (code));
            };
        };
    };

    private func save(trans : Types.Record) : () {
        switch (trans.transType) {
            case (#claim) {
                _rewardRecordBuffer.add(trans);
            };
            case (_) {
                _stakingRecordBuffer.add(trans);
            };
        };
    };

    // --------------------------- ACL ------------------------------------
    private stable var _admins : [Principal] = [initMsg.caller];
    public shared (msg) func setAdmins(admins : [Principal]) : async () {
        _checkPermission(msg.caller);
        _admins := admins;
    };
    public query func getAdmins() : async Result.Result<[Principal], Types.Error> {
        return #ok(_admins);
    };
    private func _checkAdminPermission(caller : Principal) {
        assert (_hasAdminPermission(caller));
    };

    private func _hasAdminPermission(caller : Principal) : Bool {
        return (CollectionUtils.arrayContains<Principal>(_admins, caller, Principal.equal) or _hasPermission(caller));
    };

    private func _checkPermission(caller : Principal) {
        assert (_hasPermission(caller));
    };

    private func _hasPermission(caller : Principal) : Bool {
        return Prim.isController(caller);
    };

    var updateTokenFeeId = Timer.recurringTimer<system>(#seconds(600), updateTokenFee);
    var unlockId = Timer.recurringTimer<system>(#seconds(60), unlock);

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };
};
