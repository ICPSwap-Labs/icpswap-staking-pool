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

    private stable var _autoUnlockTimes = 200;
    private stable var _arithmeticFactor = 1_000_000_000_000_000_000_00;
    private stable var _totalRewardFee = 0;
    private stable var _receivedRewardFee = 0;
    private stable var _rewardFee = params.rewardFee;
    private stable var _feeReceiverCid = params.feeReceiverCid;

    private stable var _poolInfo : Types.StakingPoolState = {
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

    private stable var _ledgerAmount = {
        var claim = 0.00;
        var staking = 0.00;
        var unStaking = 0.00;
        var stakingBalance = 0.00;
        var rewardBalance = 0.00;
    };

    private stable var _userInfoList : [(Principal, Types.UserInfo)] = [];
    private var _userInfoMap = HashMap.fromIter<Principal, Types.UserInfo>(_userInfoList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _lockList : [(Principal, Nat)] = [];
    private var _lockMap = HashMap.fromIter<Principal, Nat>(_lockList.vals(), 0, Principal.equal, Principal.hash);

    private stable var _stakingRecords : [Types.Record] = [];
    private var _stakingRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);
    private stable var _rewardRecords : [Types.Record] = [];
    private var _rewardRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);

    system func preupgrade() {
        _userInfoList := Iter.toArray(_userInfoMap.entries());
        _lockList := Iter.toArray(_lockMap.entries());
        _stakingRecords := Buffer.toArray(_stakingRecordBuffer);
        _rewardRecords := Buffer.toArray(_rewardRecordBuffer);
    };
    system func postupgrade() {
        _userInfoList := [];
        _lockList := [];
        for (record in _stakingRecords.vals()) {
            _stakingRecordBuffer.add(record);
        };
        for (record in _rewardRecords.vals()) {
            _rewardRecordBuffer.add(record);
        };
        _stakingRecords := [];
        _rewardRecords := [];
    };

    public shared (msg) func stop() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        _poolInfo.bonusEndTime := _getTime();
        Timer.cancelTimer(_updateTokenInfoId);
        Timer.cancelTimer(_unlockId);
        return _getPoolInfo();
    };

    public shared (msg) func updateStakingPool(params : Types.UpdateStakingPool) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _poolInfo.rewardToken := params.rewardToken;
        _poolInfo.rewardTokenFee := params.rewardTokenFee;
        _poolInfo.rewardTokenSymbol := params.rewardTokenSymbol;
        _poolInfo.rewardTokenDecimals := params.rewardTokenDecimals;
        _poolInfo.stakingToken := params.stakingToken;
        _poolInfo.stakingTokenFee := params.stakingTokenFee;
        _poolInfo.stakingTokenSymbol := params.stakingTokenSymbol;
        _poolInfo.stakingTokenDecimals := params.stakingTokenDecimals;

        _poolInfo.startTime := params.startTime;
        _poolInfo.bonusEndTime := params.bonusEndTime;
        _poolInfo.rewardPerTime := params.rewardPerTime;
        return #ok(true);
    };

    public shared (msg) func clearLocks() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        var size = _lockMap.size();
        _lockMap := HashMap.HashMap<Principal, Nat>(0, Principal.equal, Principal.hash);
        return #ok(size);
    };

    public shared (msg) func setAutoUnlockTimes(n : Nat) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        if (n != 0) {
            _autoUnlockTimes := n;
        };
        return #ok(_autoUnlockTimes);
    };

    public shared (msg) func setTime(startTime : Nat, bonusEndTime : Nat) : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        _poolInfo.startTime := startTime;
        _poolInfo.bonusEndTime := bonusEndTime;
        return _getPoolInfo();
    };

    public shared (msg) func withdrawRemainingRewardToken(amount : Nat, to : Principal) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        let currentTime = _getTime();
        if (_poolInfo.bonusEndTime > currentTime) {
            return #err("Staking pool is not over");
        };
        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            if (userInfo.amount > 0) {
                return #err("User Token have not been fully withdrawn");
            };
        };
        var token : Types.Token = {
            address = _poolInfo.rewardToken.address;
            standard = _poolInfo.rewardToken.standard;
        };
        let withdrawAmount = Nat.sub(amount, _poolInfo.rewardTokenFee);
        return await _pay(token, Principal.fromActor(this), null, to, null, withdrawAmount);
    };

    public shared func subaccountBalanceOf(owner : Principal) : async Result.Result<Nat, Text> {
        var subaccount : ?Blob = Option.make(Types.principalToBlob(owner));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
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
        var locked = _lock(owner);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                _unLock(owner);
                return #err("The balance of subaccount is 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                _unLock(owner);
                return #err("The balance of subaccount is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = owner; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _unLock(owner);
                    return #ok("Refund Successfully");
                };
                case (#Err(message)) {
                    _unLock(owner);
                    return #err("RefundError:" #debug_show (message));
                };
            };
        } catch (e) {
            _unLock(owner);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func refundUserStaking(owner : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);
        let currentTime = _getTime();
        if (_poolInfo.bonusEndTime > currentTime) {
            return #err("Staking pool is not over");
        };
        var locked = _lock(owner);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            switch (await _harvest(owner)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    _unLock(owner);
                    return #err(err);
                };
            };

            var _userInfo : Types.UserInfo = _getUserInfo(owner);
            var withdrawAmount = _userInfo.amount;

            if (withdrawAmount == 0) {
                _unLock(owner);
                return #err("The amount of withdrawal can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (withdrawAmount < fee) {
                _unLock(owner);
                return #err("The amount of withdrawal is less than the staking token transfer fee");
            };
            switch (await _pay(_poolInfo.stakingToken, Principal.fromActor(this), null, owner, null, withdrawAmount - fee)) {
                case (#ok(amount)) {
                    var amount = withdrawAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _poolInfo.totalDeposit := Nat.sub(_poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(owner, _userInfo);
                    let nowTime = _getTime();
                    _save({
                        to = owner;
                        from = Principal.fromActor(this);
                        rewardStandard = _poolInfo.rewardToken.standard;
                        rewardToken = _poolInfo.rewardToken.address;
                        rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
                        rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
                        stakingStandard = _poolInfo.rewardToken.standard;
                        stakingToken = _poolInfo.stakingToken.address;
                        stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #withdraw;
                    });
                    _unLock(owner);
                    return #ok("Withdrew Successfully");
                };
                case (#err(code)) {
                    _unLock(owner);
                    return #err("Withdraw::withdrawed error:" #debug_show (code));
                };
            };
        } catch (e) {
            _unLock(owner);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public query (msg) func unclaimdRewardFee() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        return #ok(Nat.sub(_totalRewardFee, _receivedRewardFee));
    };

    public shared (msg) func withdrawRewardFee() : async Result.Result<Text, Text> {
        assert (Principal.equal(msg.caller, _feeReceiverCid));
        var locked = _lock(_feeReceiverCid);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.rewardToken.address, _poolInfo.rewardToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = null;
            });
            if (not (balance > 0)) {
                _unLock(_feeReceiverCid);
                return #err("The reward token balance of pool is 0");
            };
            var fee = _poolInfo.rewardTokenFee;
            if (not (balance > fee)) {
                _unLock(_feeReceiverCid);
                return #err("The reward token balance of pool is less than the reward token transfer fee");
            };
            let pending = Nat.sub(_totalRewardFee, _receivedRewardFee);
            if (not (balance > pending)) {
                _unLock(_feeReceiverCid);
                return #err("The reward token balance of pool is less than the reward fee");
            };
            if (not (pending > fee)) {
                _unLock(_feeReceiverCid);
                return #err("The unclaimd reward token tax fee of pool is less than the reward token transfer fee");
            };

            var amount : Nat = Nat.sub(pending, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = _feeReceiverCid; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _unLock(_feeReceiverCid);
                    _receivedRewardFee += pending;
                    return #ok("Claimed Successfully");
                };
                case (#Err(message)) {
                    _unLock(_feeReceiverCid);
                    return #err("Claim::Claimed error:" #debug_show (message));
                };
            };
        } catch (e) {
            _unLock(_feeReceiverCid);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func deposit() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let currentTime = _getTime();
        if (_poolInfo.startTime > currentTime or _poolInfo.bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(_poolInfo.stakingToken.standard, "ICP") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_poolInfo.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };
        var locked = _lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                _unLock(msg.caller);
                return #err("The amount of deposit can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                _unLock(msg.caller);
                return #err("The amount of deposit is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);

            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    _unLock(msg.caller);
                    return #err(err);
                };
            };
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = poolCanisterId; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _ledgerAmount.staking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, amount);
                    _poolInfo.totalDeposit := Nat.add(_poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    var nowTime = _getTime();
                    _save({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = _poolInfo.rewardToken.standard;
                        rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
                        rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
                        rewardToken = _poolInfo.rewardToken.address;
                        stakingStandard = _poolInfo.stakingToken.standard;
                        stakingToken = _poolInfo.stakingToken.address;
                        stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #deposit;
                    });
                    _unLock(msg.caller);
                    return #ok("Deposited Successfully");
                };
                case (#Err(message)) {
                    _unLock(msg.caller);
                    return #err("Deposit::Deposited error:" #debug_show (message));
                };
            };
        } catch (e) {
            _unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func depositFrom(amount : Nat) : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let currentTime = _getTime();
        if (_poolInfo.startTime > currentTime or _poolInfo.bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(_poolInfo.stakingToken.standard, "ICP") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_poolInfo.stakingToken.standard));
        };
        var locked = _lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {

            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = msg.caller;
                subaccount = null;
            });
            if (not (balance > 0)) {
                _unLock(msg.caller);
                return #err("The balance can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                _unLock(msg.caller);
                return #err("The balance is less than the staking token transfer fee");
            };
            if (amount > balance) {
                _unLock(msg.caller);
                return #err("The deposit amount is higher than the account balance");
            };
            var deposit_amount : Nat = Nat.sub(amount, fee);

            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    _unLock(msg.caller);
                    return #err(err);
                };
            };
            var poolCanisterId = Principal.fromActor(this);
            switch (await tokenAdapter.transferFrom({ from = { owner = msg.caller; subaccount = null }; to = { owner = poolCanisterId; subaccount = null }; amount = deposit_amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _ledgerAmount.staking += Float.div(_natToFloat(deposit_amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, deposit_amount);
                    _poolInfo.totalDeposit := Nat.add(_poolInfo.totalDeposit, deposit_amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    var nowTime = _getTime();
                    _save({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = _poolInfo.rewardToken.standard;
                        rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
                        rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
                        rewardToken = _poolInfo.rewardToken.address;
                        stakingStandard = _poolInfo.stakingToken.standard;
                        stakingToken = _poolInfo.stakingToken.address;
                        stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
                        amount = deposit_amount;
                        timestamp = nowTime;
                        transType = #depositFrom;
                    });
                    _unLock(msg.caller);
                    return #ok("Deposited Successfully");
                };
                case (#Err(message)) {
                    _unLock(msg.caller);
                    return #err("Deposit::Deposited error:" #debug_show (message));
                };
            };
        } catch (e) {
            _unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func harvest() : async Result.Result<Nat, Text> {
        var locked = _lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };
        try {
            let result = await _harvest(msg.caller);
            _unLock(msg.caller);
            return result;
        } catch (e) {
            _unLock(msg.caller);
            return #err("Harvest Exception: " #debug_show (Error.message(e)));
        };
    };

    public shared (msg) func withdraw(amount : Nat) : async Result.Result<Text, Text> {
        var locked = _lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            switch (await _harvest(msg.caller)) {
                case (#ok(status)) {};
                case (#err(err)) {
                    _unLock(msg.caller);
                    return #err(err);
                };
            };

            var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
            var withdrawAmount = if (amount > _userInfo.amount) {
                _userInfo.amount;
            } else {
                amount;
            };
            if (withdrawAmount == 0) {
                _unLock(msg.caller);
                return #err("The amount of withdrawal can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (withdrawAmount < fee) {
                _unLock(msg.caller);
                return #err("The amount of withdrawal is less than the staking token transfer fee");
            };
            switch (await _pay(_poolInfo.stakingToken, Principal.fromActor(this), null, msg.caller, null, withdrawAmount - fee)) {
                case (#ok(amount)) {
                    var amount = withdrawAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _poolInfo.totalDeposit := Nat.sub(_poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    let nowTime = _getTime();
                    _save({
                        to = msg.caller;
                        from = Principal.fromActor(this);
                        rewardStandard = _poolInfo.rewardToken.standard;
                        rewardToken = _poolInfo.rewardToken.address;
                        rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
                        rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
                        stakingStandard = _poolInfo.rewardToken.standard;
                        stakingToken = _poolInfo.stakingToken.address;
                        stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
                        stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
                        amount = amount;
                        timestamp = nowTime;
                        transType = #withdraw;
                    });
                    _unLock(msg.caller);
                    return #ok("Withdrew Successfully");
                };
                case (#err(code)) {
                    _unLock(msg.caller);
                    return #err("Withdraw::withdrawed error:" #debug_show (code));
                };
            };
        } catch (e) {
            _unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func claim() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        if (Text.notEqual(_poolInfo.stakingToken.standard, "ICP") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_poolInfo.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };
        var locked = _lock(msg.caller);
        if (not locked) {
            return #err("The lock server is busy, and please try again later");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                _unLock(msg.caller);
                return #err("The amount of claim is 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                _unLock(msg.caller);
                return #err("The amount of claim is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = msg.caller; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _unLock(msg.caller);
                    return #ok("Claimed Successfully");
                };
                case (#Err(message)) {
                    _unLock(msg.caller);
                    return #err("Claim::Claimed error:" #debug_show (message));
                };
            };
        } catch (e) {
            _unLock(msg.caller);
            return #err("InternalError" # (debug_show (Error.message(e))));
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    public query func findAllUserInfo(offset : Nat, limit : Nat) : async Result.Result<Types.Page<(Principal, Types.PublicUserInfo)>, Text> {
        var buffer : Buffer.Buffer<(Principal, Types.PublicUserInfo)> = Buffer.Buffer<(Principal, Types.PublicUserInfo)>(_userInfoMap.size());
        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
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
        return #ok(Iter.toArray(_lockMap.entries()));
    };

    public query func getPoolInfo() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        return _getPoolInfo();
    };

    public query func pendingReward(user : Principal) : async Result.Result<Nat, Text> {
        return #ok(_pendingReward(user));
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

    private func _getPoolInfo() : Result.Result<Types.PublicStakingPoolInfo, Text> {
        return #ok({
            rewardToken = _poolInfo.rewardToken;
            rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
            rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
            rewardTokenFee = _poolInfo.rewardTokenFee;
            stakingToken = _poolInfo.stakingToken;
            stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
            stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
            stakingTokenFee = _poolInfo.stakingTokenFee;

            startTime = _poolInfo.startTime;
            bonusEndTime = _poolInfo.bonusEndTime;
            lastRewardTime = _poolInfo.lastRewardTime;
            rewardPerTime = _poolInfo.rewardPerTime;
            rewardFee = _rewardFee;
            accPerShare = _poolInfo.accPerShare;

            totalDeposit = _poolInfo.totalDeposit;
            rewardDebt = _poolInfo.rewardDebt;
        });
    };

    private func _unlock() : async () {
        let nowTimes = _getTime();
        for ((userPrincipal, lockTime) in _lockMap.entries()) {
            if ((SafeUint.Uint256(nowTimes).sub(SafeUint.Uint256(lockTime)).val()) > _autoUnlockTimes) {
                _unLock(userPrincipal);
            };
        };
    };

    private func _lock(caller : Principal) : Bool {
        switch (_lockMap.get(caller)) {
            case (null) {
                var nowTime = _getTime();
                _lockMap.put(caller, nowTime);
                return true;
            };
            case (?lockUser) {
                return false;
            };
        };
    };

    private func _unLock(caller : Principal) : () {
        _lockMap.delete(caller);
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _updateTokenInfo() : async () {
        let stakingTokenAdapter = TokenFactory.getAdapter(
            _poolInfo.stakingToken.address,
            _poolInfo.stakingToken.standard,
        );
        _poolInfo.stakingTokenFee := await stakingTokenAdapter.fee();
        _poolInfo.stakingTokenDecimals := Nat8.toNat(await stakingTokenAdapter.decimals());
        _poolInfo.stakingTokenSymbol := await stakingTokenAdapter.symbol();

        let rewardTokenAdapter = TokenFactory.getAdapter(
            _poolInfo.rewardToken.address,
            _poolInfo.rewardToken.standard,
        );
        _poolInfo.rewardTokenFee := await rewardTokenAdapter.fee();
        _poolInfo.rewardTokenDecimals := Nat8.toNat(await rewardTokenAdapter.decimals());
        _poolInfo.rewardTokenSymbol := await rewardTokenAdapter.symbol();
    };

    private func _getUserInfo(user : Principal) : Types.UserInfo {
        switch (_userInfoMap.get(user)) {
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

    private func _pay(token : Types.Token, payer : Principal, payerSubAccount : ?Blob, recipient : Principal, recipientSubAccount : ?Blob, value : Nat) : async Result.Result<Nat, Text> {
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

    private func _getRewardInterval(lastRewardTime : Nat, nowTime : Nat) : Nat {
        if (lastRewardTime < _poolInfo.bonusEndTime) {
            if (nowTime <= _poolInfo.bonusEndTime) {
                return Nat.sub(nowTime, lastRewardTime);
            } else {
                return Nat.sub(_poolInfo.bonusEndTime, lastRewardTime);
            };
        } else {
            return 0;
        };
    };

    private func _updatePool() : async () {
        var nowTime = _getTime();
        if (nowTime <= _poolInfo.lastRewardTime) { return };
        if (_poolInfo.totalDeposit == 0) {
            _poolInfo.lastRewardTime := nowTime;
            return;
        };
        var rewardInterval : Nat = _getRewardInterval(_poolInfo.lastRewardTime, nowTime);
        var reward : Nat = Nat.mul(rewardInterval, _poolInfo.rewardPerTime);
        _poolInfo.accPerShare := Nat.add(_poolInfo.accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _poolInfo.totalDeposit));
        _poolInfo.lastRewardTime := nowTime;
    };

    private func _pendingReward(user : Principal) : Nat {
        var nowTime = _getTime();
        var _userInfo : Types.UserInfo = _getUserInfo(user);
        if (nowTime > _poolInfo.lastRewardTime and _poolInfo.totalDeposit != 0) {
            var rewardInterval : Nat = _getRewardInterval(_poolInfo.lastRewardTime, nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _poolInfo.rewardPerTime);
            _poolInfo.accPerShare := Nat.add(_poolInfo.accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _poolInfo.totalDeposit));
        };
        var rewardAmount = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, _poolInfo.accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        let rewardTokenTaxFee : Nat = Nat.div(Nat.mul(rewardAmount, _rewardFee), 100);
        if (rewardTokenTaxFee > 0) {
            rewardAmount := rewardAmount - rewardTokenTaxFee;
        };
        return rewardAmount;
    };

    private func _natToFloat(amount : Nat) : Float {
        Float.fromInt(amount);
    };

    private func _harvest(caller : Principal) : async Result.Result<Nat, Text> {
        await _updatePool();
        var _userInfo : Types.UserInfo = _getUserInfo(caller);
        var pending : Nat = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, _poolInfo.accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        if (pending == 0 or pending < _poolInfo.rewardTokenFee) {
            return #ok(0);
        };
        var rewardAmount = pending;
        let rewardFee : Nat = Nat.div(Nat.mul(rewardAmount, _rewardFee), 100);
        if (rewardFee > 0) {
            _totalRewardFee += rewardFee;
            rewardAmount := rewardAmount - rewardFee;
        };

        if (rewardAmount < _poolInfo.rewardTokenFee) {
            _totalRewardFee -= rewardFee;
            return #ok(0);
        };
        switch (await _pay(_poolInfo.rewardToken, Principal.fromActor(this), null, caller, null, rewardAmount - _poolInfo.rewardTokenFee)) {
            case (#ok(amount)) {
                _ledgerAmount.claim += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.rewardTokenDecimals)));
                _poolInfo.rewardDebt := _poolInfo.rewardDebt + pending;
                _userInfo.rewardDebt := Nat.div(Nat.mul(_userInfo.amount, _poolInfo.accPerShare), _arithmeticFactor);
                _userInfoMap.put(caller, _userInfo);
                var nowTime = _getTime();
                _save({
                    from = Principal.fromActor(this);
                    to = caller;
                    rewardStandard = _poolInfo.rewardToken.standard;
                    rewardToken = _poolInfo.rewardToken.address;
                    rewardTokenSymbol = _poolInfo.rewardTokenSymbol;
                    rewardTokenDecimals = _poolInfo.rewardTokenDecimals;
                    stakingStandard = _poolInfo.stakingToken.standard;
                    stakingToken = _poolInfo.stakingToken.address;
                    stakingTokenDecimals = _poolInfo.stakingTokenDecimals;
                    stakingTokenSymbol = _poolInfo.stakingTokenSymbol;
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

    private func _save(trans : Types.Record) : () {
        switch (trans.transType) {
            case (#claim) {
                _rewardRecordBuffer.add(trans);
            };
            case (_) {
                _stakingRecordBuffer.add(trans);
            };
        };
    };

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

    let _updateTokenInfoId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _updateTokenInfo);
    let _unlockId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(60), _unlock);

    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };
};
