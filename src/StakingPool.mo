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
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";
import Result "mo:base/Result";
import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";

import CollectionUtils "mo:commons/utils/CollectionUtils";

import TokenFactory "mo:token-adapter/TokenFactory";

import Types "Types";

shared (initMsg) actor class StakingPool(params : Types.InitRequests) : async Types.IStakingPool = this {

    private stable var _autoUnlockTimes = 200;
    private stable var _arithmeticFactor = 1_000_000_000_000_000_000_00;
    private stable var _totalRewardFee = 0;
    private stable var _receivedRewardFee = 0;

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

        var creator = params.creator;
        var createTime = params.createTime;

        var lastRewardTime = 0;
        var accPerShare = 0;
        var totalDeposit = 0;
        var rewardDebt = 0;
    };

    private stable var _ledgerAmount : Types.LedgerAmountState = {
        var harvest = 0.00;
        var staking = 0.00;
        var unStaking = 0.00;
    };

    private stable var _userInfoList : [(Principal, Types.UserInfo)] = [];
    private var _userInfoMap = HashMap.fromIter<Principal, Types.UserInfo>(_userInfoList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _stakingRecords : [Types.Record] = [];
    private var _stakingRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);
    private stable var _rewardRecords : [Types.Record] = [];
    private var _rewardRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);
    private stable var _preRewardRecords : [Types.Record] = [];
    private var _preRewardRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);

    system func preupgrade() {
        _userInfoList := Iter.toArray(_userInfoMap.entries());
        _stakingRecords := Buffer.toArray(_stakingRecordBuffer);
        _rewardRecords := Buffer.toArray(_rewardRecordBuffer);
        _preRewardRecords := Buffer.toArray(_preRewardRecordBuffer);
        _errorLogList := Buffer.toArray(_errorLogBuffer);

    };
    system func postupgrade() {
        _userInfoList := [];
        for (record in _stakingRecords.vals()) {
            _stakingRecordBuffer.add(record);
        };
        for (record in _rewardRecords.vals()) {
            _rewardRecordBuffer.add(record);
        };
        for (record in _preRewardRecords.vals()) {
            _preRewardRecordBuffer.add(record);
        };
        for (record in _errorLogList.vals()) { _errorLogBuffer.add(record) };
        _stakingRecords := [];
        _rewardRecords := [];
        _errorLogList := [];
        _preRewardRecords := [];
    };

    public shared (msg) func stop() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);

        _poolInfo.bonusEndTime := _getTime();
        Timer.cancelTimer(_updateTokenInfoId);
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
            return #err("Staking pool is not finish");
        };
        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            if (userInfo.amount > 0) {
                return #err("User Token have not been fully unstake");
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
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func refundSubaccountBalance(owner : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

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
            if (not (balance > 0)) {
                return #err("The balance of subaccount is 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                return #err("The balance of subaccount is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = owner; subaccount = null }; amount = amount; fee = null; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    return #ok("Refund Successfully");
                };
                case (#Err(message)) {
                    return #err("RefundError:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func refundUserStaking(owner : Principal) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

        let currentTime = _getTime();
        if (_poolInfo.bonusEndTime > currentTime) {
            return #err("Staking pool is not finish");
        };

        try {
            _preHarvest(owner);

            var _userInfo : Types.UserInfo = _getUserInfo(owner);
            var refundAmount = _userInfo.amount;

            if (refundAmount == 0) {
                return #err("The amount of refund can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (refundAmount < fee) {
                return #err("The amount of refund is less than the staking token transfer fee");
            };
            switch (await _pay(_poolInfo.stakingToken, Principal.fromActor(this), null, owner, null, refundAmount - fee)) {
                case (#ok(amount)) {
                    var amount = refundAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _poolInfo.totalDeposit := Nat.sub(_poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(owner, _userInfo);
                    let nowTime = _getTime();
                    _saveRecord({
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
                        transType = #unstake;
                    });
                    return #ok("Refund user staking Successfully");
                };
                case (#err(code)) {
                    return #err("Refund user staking error:" #debug_show (code));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public query (msg) func unclaimdRewardFee() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        return #ok(Nat.sub(_totalRewardFee, _receivedRewardFee));
    };

    public shared (msg) func withdrawRewardFee() : async Result.Result<Text, Text> {
        assert (Principal.equal(msg.caller, params.feeReceiverCid));

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.rewardToken.address, _poolInfo.rewardToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = null;
            });
            if (not (balance > 0)) {
                return #err("The reward token balance of pool is 0");
            };
            var fee = _poolInfo.rewardTokenFee;
            if (not (balance > fee)) {
                return #err("The reward token balance of pool is less than the reward token transfer fee");
            };
            let pending = Nat.sub(_totalRewardFee, _receivedRewardFee);
            if (not (balance > pending)) {
                return #err("The reward token balance of pool is less than the reward fee");
            };
            if (not (pending > fee)) {
                return #err("The unclaimd reward token fee of pool is less than the reward token transfer fee");
            };

            var amount : Nat = Nat.sub(pending, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = params.feeReceiverCid; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _receivedRewardFee += pending;
                    return #ok("Withdraw reward fee successfully");
                };
                case (#Err(message)) {
                    return #err("Withdraw reward fee error:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func stake() : async Result.Result<Text, Text> {
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

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                return #err("The amount of stake can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                return #err("The amount of stake is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);

            _preHarvest(msg.caller);

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
                    _saveRecord({
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
                        transType = #stake;
                    });
                    return #ok("Stake Successfully");
                };
                case (#Err(message)) {
                    return #err("Stake error:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func stakeFrom(amount : Nat) : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let currentTime = _getTime();
        if (_poolInfo.startTime > currentTime or _poolInfo.bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(_poolInfo.stakingToken.standard, "ICP") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC1") and Text.notEqual(_poolInfo.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_poolInfo.stakingToken.standard));
        };

        try {
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = msg.caller;
                subaccount = null;
            });
            if (not (balance > 0)) {
                return #err("The balance can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                return #err("The balance is less than the staking token transfer fee");
            };
            if (amount > balance) {
                return #err("The stake amount is higher than the account balance");
            };
            var stake_amount : Nat = Nat.sub(amount, fee);

            _preHarvest(msg.caller);

            var poolCanisterId = Principal.fromActor(this);
            switch (await tokenAdapter.transferFrom({ from = { owner = msg.caller; subaccount = null }; to = { owner = poolCanisterId; subaccount = null }; amount = stake_amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _ledgerAmount.staking += Float.div(_natToFloat(stake_amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, stake_amount);
                    _poolInfo.totalDeposit := Nat.add(_poolInfo.totalDeposit, stake_amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    var nowTime = _getTime();
                    _saveRecord({
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
                        amount = stake_amount;
                        timestamp = nowTime;
                        transType = #stake;
                    });
                    return #ok("Stake Successfully");
                };
                case (#Err(message)) {
                    return #err("Stake error:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func unstake(amount : Nat) : async Result.Result<Text, Text> {
        try {
            _preHarvest(msg.caller);

            var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
            var unstakeAmount = if (amount > _userInfo.amount) {
                _userInfo.amount;
            } else {
                amount;
            };
            if (unstakeAmount == 0) {
                return #err("The amount of unstake can’t be 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (unstakeAmount < fee) {
                return #err("The amount of unstake is less than the staking token transfer fee");
            };
            switch (await _pay(_poolInfo.stakingToken, Principal.fromActor(this), null, msg.caller, null, unstakeAmount - fee)) {
                case (#ok(amount)) {
                    var amount = unstakeAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_poolInfo.stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _poolInfo.totalDeposit := Nat.sub(_poolInfo.totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _poolInfo.accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    let nowTime = _getTime();
                    _saveRecord({
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
                        transType = #unstake;
                    });
                    return #ok("Unstake Successfully");
                };
                case (#err(code)) {
                    return #err("Unstake error:" #debug_show (code));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func harvest() : async Result.Result<Bool, Text> {
        try {
            _preHarvest(msg.caller);
            return #ok(true);
        } catch (e) {
            return #err("Harvest error: " #debug_show (Error.message(e)));
        };
    };

    public shared func claimReward(owner : Principal) : async Result.Result<Bool, Text> {
        var buffer = Buffer.Buffer<Types.Record>(_preRewardRecordBuffer.size());
        for (_preReward in _preRewardRecordBuffer.vals()) {
            if (Principal.equal(_preReward.to, owner)) {
                switch (await _pay(_poolInfo.rewardToken, Principal.fromActor(this), null, _preReward.to, null, _preReward.amount - _poolInfo.rewardTokenFee)) {
                    case (#ok(amount)) {
                        _saveRecord(_preReward);
                    };
                    case (#err(code)) {
                        _errorLogBuffer.add("Claim reward failed at " # debug_show (_getTime()) # ". Code: " # debug_show (code) # ". Reward info: " # debug_show (_preReward));
                    };
                };
            } else {
                buffer.add(_preReward);
            };
        };
        _preRewardRecordBuffer := buffer;
        return #ok(true);
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

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_poolInfo.stakingToken.address, _poolInfo.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (not (balance > 0)) {
                return #err("The amount of claim is 0");
            };
            var fee = _poolInfo.stakingTokenFee;
            if (not (balance > fee)) {
                return #err("The amount of claim is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, fee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = msg.caller; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    return #ok("Claim Successfully");
                };
                case (#Err(message)) {
                    return #err("Claim error:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    public shared func getLedgerInfo() : async Result.Result<Types.LedgerAmountInfo, Types.Error> {
        return #ok({
            harvest = _ledgerAmount.harvest;
            staking = _ledgerAmount.staking;
            unStaking = _ledgerAmount.unStaking;
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
            rewardFee = params.rewardFee;
            accPerShare = _poolInfo.accPerShare;

            totalDeposit = _poolInfo.totalDeposit;
            rewardDebt = _poolInfo.rewardDebt;

            creator = _poolInfo.creator;
            createTime = _poolInfo.createTime;
        });
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

    private func _pendingReward(user : Principal) : Nat {
        var nowTime = _getTime();
        var _userInfo : Types.UserInfo = _getUserInfo(user);
        if (nowTime > _poolInfo.lastRewardTime and _poolInfo.totalDeposit != 0) {
            var rewardInterval : Nat = _getRewardInterval(_poolInfo.lastRewardTime, nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _poolInfo.rewardPerTime);
            _poolInfo.accPerShare := Nat.add(_poolInfo.accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _poolInfo.totalDeposit));
        };
        var rewardAmount = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, _poolInfo.accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        let rewardTokenTaxFee : Nat = Nat.div(Nat.mul(rewardAmount, params.rewardFee), 100);
        if (rewardTokenTaxFee > 0) {
            rewardAmount := rewardAmount - rewardTokenTaxFee;
        };
        return rewardAmount;
    };

    private func _natToFloat(amount : Nat) : Float {
        Float.fromInt(amount);
    };

    private func _preHarvest(caller : Principal) : () {
        var nowTime = _getTime();
        var accPerShare = _poolInfo.accPerShare;
        var lastRewardTime = nowTime;
        if (_poolInfo.totalDeposit > 0) {
            var rewardInterval : Nat = _getRewardInterval(_poolInfo.lastRewardTime, nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _poolInfo.rewardPerTime);
            accPerShare := Nat.add(_poolInfo.accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _poolInfo.totalDeposit));
        };

        var _userInfo : Types.UserInfo = _getUserInfo(caller);
        var pending : Nat = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        if (pending == 0 or pending < _poolInfo.rewardTokenFee) {
            return;
        };
        var rewardAmount = pending;
        let rewardFee : Nat = Nat.div(Nat.mul(rewardAmount, params.rewardFee), 100);
        if (rewardFee > 0) {
            _totalRewardFee += rewardFee;
            rewardAmount := rewardAmount - rewardFee;
        };

        if (rewardAmount < _poolInfo.rewardTokenFee) {
            _totalRewardFee -= rewardFee;
            return;
        };

        _ledgerAmount.harvest += Float.div(_natToFloat(Nat.sub(rewardAmount, _poolInfo.rewardTokenFee)), Float.pow(10, _natToFloat(_poolInfo.rewardTokenDecimals)));
        _poolInfo.rewardDebt := _poolInfo.rewardDebt + pending;
        _poolInfo.accPerShare := accPerShare;
        _poolInfo.lastRewardTime := lastRewardTime;
        _userInfo.rewardDebt := Nat.div(Nat.mul(_userInfo.amount, accPerShare), _arithmeticFactor);
        _userInfoMap.put(caller, _userInfo);
        var _harvestRecord = {
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
            transType = #harvest;
        };
        _savePreRecord(_harvestRecord);
    };

    private func _saveRecord(trans : Types.Record) : () {
        switch (trans.transType) {
            case (#harvest) {
                _rewardRecordBuffer.add(trans);
            };
            case (_) {
                _stakingRecordBuffer.add(trans);
            };
        };
    };

    private func _savePreRecord(trans : Types.Record) : () {
        switch (trans.transType) {
            case (#harvest) {
                _rewardRecordBuffer.add(trans);
            };
            case (_) {
                _stakingRecordBuffer.add(trans);
            };
        };
    };

    // --------------------------- ERROR LOG ------------------------------------
    private stable var _errorLogList : [Text] = [];
    private var _errorLogBuffer : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
    public shared (msg) func clearErrorLog() : async () {
        _checkAdminPermission(msg.caller);
        _errorLogBuffer := Buffer.Buffer<Text>(0);
    };
    public query func getErrorLog() : async [Text] {
        return Buffer.toArray(_errorLogBuffer);
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

    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };
};
