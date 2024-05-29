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

shared (initMsg) actor class StakingPool(initArgs : Types.InitRequests) : async Types.IStakingPool = this {

    private stable var _arithmeticFactor = 1_000_000_000_000_000_000_00;

    private stable var _rewardToken = initArgs.rewardToken;
    private stable var _rewardTokenFee = initArgs.rewardTokenFee;
    private stable var _rewardTokenSymbol = initArgs.rewardTokenSymbol;
    private stable var _rewardTokenDecimals = initArgs.rewardTokenDecimals;
    private stable var _stakingToken = initArgs.stakingToken;
    private stable var _stakingTokenFee = initArgs.stakingTokenFee;
    private stable var _stakingTokenSymbol = initArgs.stakingTokenSymbol;
    private stable var _stakingTokenDecimals = initArgs.stakingTokenDecimals;
    private stable var _rewardPerTime = initArgs.rewardPerTime;
    private stable var _startTime = initArgs.startTime;
    private stable var _bonusEndTime = initArgs.bonusEndTime;
    private stable var _creator = initArgs.creator;
    private stable var _createTime = initArgs.createTime;
    private stable var _lastRewardTime = 0;
    private stable var _accPerShare = 0;
    private stable var _totalDeposit = 0;
    private stable var _rewardDebt = 0;

    private stable var _totalRewardFee = 0;
    private stable var _receivedRewardFee = 0;

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

        _bonusEndTime := _getTime();
        Timer.cancelTimer(_updateTokenInfoId);
        return _getPoolInfo();
    };

    public shared (msg) func updateStakingPool(params : Types.UpdateStakingPool) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);

        _rewardToken := params.rewardToken;
        _rewardTokenFee := params.rewardTokenFee;
        _rewardTokenSymbol := params.rewardTokenSymbol;
        _rewardTokenDecimals := params.rewardTokenDecimals;
        _stakingToken := params.stakingToken;
        _stakingTokenFee := params.stakingTokenFee;
        _stakingTokenSymbol := params.stakingTokenSymbol;
        _stakingTokenDecimals := params.stakingTokenDecimals;

        _startTime := params.startTime;
        _bonusEndTime := params.bonusEndTime;
        _rewardPerTime := params.rewardPerTime;
        return #ok(true);
    };

    public shared (msg) func setTime(startTime : Nat, bonusEndTime : Nat) : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);

        _startTime := startTime;
        _bonusEndTime := bonusEndTime;
        return _getPoolInfo();
    };

    public shared (msg) func withdrawRemainingRewardToken(amount : Nat, to : Principal) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);

        let currentTime = _getTime();
        if (_bonusEndTime > currentTime) {
            return #err("Staking pool is not finish");
        };
        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            if (userInfo.amount > 0) {
                return #err("User Token have not been fully unstake");
            };
        };
        var token : Types.Token = {
            address = _rewardToken.address;
            standard = _rewardToken.standard;
        };
        let withdrawAmount = Nat.sub(amount, _rewardTokenFee);
        return await _pay(token, Principal.fromActor(this), null, to, null, withdrawAmount);
    };

    public shared func subaccountBalanceOf(owner : Principal) : async Result.Result<Nat, Text> {
        var subaccount : ?Blob = Option.make(Types.principalToBlob(owner));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_stakingToken.address, _stakingToken.standard);
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
            let tokenAdapter = TokenFactory.getAdapter(_stakingToken.address, _stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (balance <= 0) {
                return #err("The balance of subaccount is 0");
            };

            if (balance <= _stakingTokenFee) {
                return #err("The balance of subaccount is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, _stakingTokenFee);
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
        if (_bonusEndTime > currentTime) {
            return #err("Staking pool is not finish");
        };

        try {
            var _userInfo : Types.UserInfo = _getUserInfo(owner);
            var refundAmount = _userInfo.amount;

            if (refundAmount == 0) {
                return #err("The amount of refund can't be 0");
            };
            var fee = _stakingTokenFee;
            if (refundAmount < fee) {
                return #err("The amount of refund is less than the staking token transfer fee");
            };
            switch (await _pay(_stakingToken, Principal.fromActor(this), null, owner, null, refundAmount - fee)) {
                case (#ok(amount)) {
                    _preHarvest(owner);
                    var amount = refundAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _totalDeposit := Nat.sub(_totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(owner, _userInfo);
                    let nowTime = _getTime();
                    _saveRecord({
                        to = owner;
                        from = Principal.fromActor(this);
                        rewardStandard = _rewardToken.standard;
                        rewardToken = _rewardToken.address;
                        rewardTokenDecimals = _rewardTokenDecimals;
                        rewardTokenSymbol = _rewardTokenSymbol;
                        stakingStandard = _rewardToken.standard;
                        stakingToken = _stakingToken.address;
                        stakingTokenSymbol = _stakingTokenSymbol;
                        stakingTokenDecimals = _stakingTokenDecimals;
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
        assert (Principal.equal(msg.caller, initArgs.feeReceiverCid));

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_rewardToken.address, _rewardToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = null;
            });
            if (balance <= 0) {
                return #err("The reward token balance of pool is 0");
            };

            if (balance <= _rewardTokenFee) {
                return #err("The reward token balance of pool is less than the reward token transfer fee");
            };
            let pending = Nat.sub(_totalRewardFee, _receivedRewardFee);
            if (balance <= pending) {
                return #err("The reward token balance of pool is less than the reward fee");
            };
            if (pending <= _rewardTokenFee) {
                return #err("The unclaimd reward token fee of pool is less than the reward token transfer fee");
            };

            var amount : Nat = Nat.sub(pending, _rewardTokenFee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = initArgs.feeReceiverCid; subaccount = null }; amount = amount; fee = ?_rewardTokenFee; memo = null; created_at_time = null })) {
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
        if (_startTime > currentTime or _bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(_stakingToken.standard, "ICP") and Text.notEqual(_stakingToken.standard, "ICRC1") and Text.notEqual(_stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_stakingToken.address, _stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (balance <= 0) {
                return #err("The amount of stake can’t be 0");
            };

            if (balance <= _stakingTokenFee) {
                return #err("The amount of stake is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, _stakingTokenFee);

            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = poolCanisterId; subaccount = null }; amount = amount; fee = ?_stakingTokenFee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _preHarvest(msg.caller);
                    var nowTime = _getTime();
                    _ledgerAmount.staking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, amount);
                    _totalDeposit := Nat.add(_totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfo.lastStakeTime := nowTime;
                    _userInfoMap.put(msg.caller, _userInfo);
                    _saveRecord({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = _rewardToken.standard;
                        rewardTokenSymbol = _rewardTokenSymbol;
                        rewardTokenDecimals = _rewardTokenDecimals;
                        rewardToken = _rewardToken.address;
                        stakingStandard = _stakingToken.standard;
                        stakingToken = _stakingToken.address;
                        stakingTokenSymbol = _stakingTokenSymbol;
                        stakingTokenDecimals = _stakingTokenDecimals;
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
        if (_startTime > currentTime or _bonusEndTime < currentTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(_stakingToken.standard, "ICP") and Text.notEqual(_stakingToken.standard, "ICRC1") and Text.notEqual(_stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_stakingToken.standard));
        };

        try {
            let tokenAdapter = TokenFactory.getAdapter(_stakingToken.address, _stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = msg.caller;
                subaccount = null;
            });
            if (balance <= 0) {
                return #err("The balance can’t be 0");
            };

            if (balance <= _stakingTokenFee) {
                return #err("The balance is less than the staking token transfer fee");
            };
            if (amount > balance) {
                return #err("The stake amount is higher than the account balance");
            };
            var stakeAmount : Nat = Nat.sub(amount, _stakingTokenFee);

            var poolCanisterId = Principal.fromActor(this);
            switch (await tokenAdapter.transferFrom({ from = { owner = msg.caller; subaccount = null }; to = { owner = poolCanisterId; subaccount = null }; amount = stakeAmount; fee = ?_stakingTokenFee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _preHarvest(msg.caller);
                    var nowTime = _getTime();
                    _ledgerAmount.staking += Float.div(_natToFloat(stakeAmount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
                    var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    _userInfo.amount := Nat.add(_userInfo.amount, stakeAmount);
                    _totalDeposit := Nat.add(_totalDeposit, stakeAmount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfo.lastStakeTime := nowTime;
                    _userInfoMap.put(msg.caller, _userInfo);
                    _saveRecord({
                        from = msg.caller;
                        to = Principal.fromActor(this);
                        rewardStandard = _rewardToken.standard;
                        rewardTokenSymbol = _rewardTokenSymbol;
                        rewardTokenDecimals = _rewardTokenDecimals;
                        rewardToken = _rewardToken.address;
                        stakingStandard = _stakingToken.standard;
                        stakingToken = _stakingToken.address;
                        stakingTokenSymbol = _stakingTokenSymbol;
                        stakingTokenDecimals = _stakingTokenDecimals;
                        amount = stakeAmount;
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
            var _userInfo : Types.UserInfo = _getUserInfo(msg.caller);
            var unstakeAmount = if (amount > _userInfo.amount) {
                _userInfo.amount;
            } else {
                amount;
            };
            if (unstakeAmount == 0) {
                return #err("The amount of unstake can’t be 0");
            };
            var fee = _stakingTokenFee;
            if (unstakeAmount < fee) {
                return #err("The amount of unstake is less than the staking token transfer fee");
            };
            switch (await _pay(_stakingToken, Principal.fromActor(this), null, msg.caller, null, unstakeAmount - fee)) {
                case (#ok(amount)) {
                    _preHarvest(msg.caller);
                    var amount = unstakeAmount;
                    _ledgerAmount.unStaking += Float.div(_natToFloat(amount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
                    _userInfo.amount := Nat.sub(_userInfo.amount, amount);
                    _totalDeposit := Nat.sub(_totalDeposit, amount);
                    _userInfo.rewardDebt := Nat.div(
                        Nat.mul(_userInfo.amount, _accPerShare),
                        _arithmeticFactor,
                    );
                    _userInfoMap.put(msg.caller, _userInfo);
                    let nowTime = _getTime();
                    _saveRecord({
                        to = msg.caller;
                        from = Principal.fromActor(this);
                        rewardStandard = _rewardToken.standard;
                        rewardToken = _rewardToken.address;
                        rewardTokenDecimals = _rewardTokenDecimals;
                        rewardTokenSymbol = _rewardTokenSymbol;
                        stakingStandard = _rewardToken.standard;
                        stakingToken = _stakingToken.address;
                        stakingTokenSymbol = _stakingTokenSymbol;
                        stakingTokenDecimals = _stakingTokenDecimals;
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
        var successBuffer = Buffer.Buffer<Types.Record>(0);
        var errorBuffer = Buffer.Buffer<Text>(0);
        for (_preReward in _preRewardRecordBuffer.vals()) {
            if (Principal.equal(_preReward.to, owner)) {
                try {
                    switch (await _pay(_rewardToken, Principal.fromActor(this), null, _preReward.to, null, _preReward.amount - _rewardTokenFee)) {
                        case (#ok(amount)) {
                            successBuffer.add(_preReward);
                        };
                        case (#err(code)) {
                            let errorMessage = "Claim reward failed at " # debug_show (_getTime()) # ". Code: " # debug_show (code) # ". Reward info: " # debug_show (_preReward);
                            errorBuffer.add(errorMessage);
                        };
                    };
                } catch (e) {
                    let errorMessage = "Claim reward failed at " # debug_show (_getTime()) # ". Error message: " # debug_show (Error.message(e)) # ". Reward info: " # debug_show (_preReward);
                    errorBuffer.add(errorMessage);
                };
            } else {
                buffer.add(_preReward);
            };
        };
        _preRewardRecordBuffer := buffer;
        for (record in successBuffer.vals()) {
            _saveRecord(record);
        };
        _errorLogBuffer.append(errorBuffer);
        return #ok(true);
    };

    public shared (msg) func claim() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        if (Text.notEqual(_stakingToken.standard, "ICP") and Text.notEqual(_stakingToken.standard, "ICRC1") and Text.notEqual(_stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (_stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(_stakingToken.address, _stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (balance <= 0) {
                return #err("The amount of claim is 0");
            };
            if (balance <= _stakingTokenFee) {
                return #err("The amount of claim is less than the staking token transfer fee");
            };
            var amount : Nat = Nat.sub(balance, _stakingTokenFee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = msg.caller; subaccount = null }; amount = amount; fee = ?_stakingTokenFee; memo = null; created_at_time = null })) {
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
                    lastRewardTime = userInfo.lastRewardTime;
                    lastStakeTime = userInfo.lastStakeTime;
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
        let _user = _getUserInfo(user);
        let _pendingRewardAmount = _pendingReward(user);
        return #ok({
            amount = _user.amount;
            rewardDebt = _user.rewardDebt;
            pendingReward = _pendingRewardAmount;
            lastRewardTime = _user.lastRewardTime;
            lastStakeTime = _user.lastStakeTime;
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
            rewardToken = _rewardToken;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardTokenFee = _rewardTokenFee;
            stakingToken = _stakingToken;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            stakingTokenFee = _stakingTokenFee;

            startTime = _startTime;
            bonusEndTime = _bonusEndTime;
            lastRewardTime = _lastRewardTime;
            rewardPerTime = _rewardPerTime;
            rewardFee = initArgs.rewardFee;
            accPerShare = _accPerShare;

            totalDeposit = _totalDeposit;
            rewardDebt = _rewardDebt;

            creator = _creator;
            createTime = _createTime;
        });
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _updateTokenInfo() : async () {
        let stakingTokenAdapter = TokenFactory.getAdapter(
            _stakingToken.address,
            _stakingToken.standard,
        );
        _stakingTokenFee := await stakingTokenAdapter.fee();
        _stakingTokenDecimals := Nat8.toNat(await stakingTokenAdapter.decimals());
        _stakingTokenSymbol := await stakingTokenAdapter.symbol();

        let rewardTokenAdapter = TokenFactory.getAdapter(
            _rewardToken.address,
            _rewardToken.standard,
        );
        _rewardTokenFee := await rewardTokenAdapter.fee();
        _rewardTokenDecimals := Nat8.toNat(await rewardTokenAdapter.decimals());
        _rewardTokenSymbol := await rewardTokenAdapter.symbol();
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
                    var lastStakeTime = 0;
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
        var _lastRewardTime = lastRewardTime;

        if (_lastRewardTime == 0) {
            _lastRewardTime := _startTime;
        };

        if (_lastRewardTime < _bonusEndTime) {
            if (nowTime <= _bonusEndTime) {
                return Nat.sub(nowTime, _lastRewardTime);
            } else {
                return Nat.sub(_bonusEndTime, _lastRewardTime);
            };
        } else {
            return 0;
        };
    };

    private func _pendingReward(user : Principal) : Nat {
        var nowTime = _getTime();
        var _userInfo : Types.UserInfo = _getUserInfo(user);
        if (nowTime > _lastRewardTime and _totalDeposit != 0) {
            var rewardInterval : Nat = _getRewardInterval(_lastRewardTime, nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _rewardPerTime);
            _accPerShare := Nat.add(_accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _totalDeposit));
        };
        var rewardAmount = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, _accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        let rewardTokenFee : Nat = Nat.div(Nat.mul(rewardAmount, initArgs.rewardFee), 1000);
        if (rewardTokenFee > 0) {
            rewardAmount := rewardAmount - rewardTokenFee;
        };
        return rewardAmount;
    };

    private func _natToFloat(amount : Nat) : Float {
        Float.fromInt(amount);
    };

    private func _preHarvest(caller : Principal) : () {
        var nowTime = _getTime();
        var accPerShare = _accPerShare;
        var lastRewardTime = nowTime;
        if (_totalDeposit > 0) {
            var rewardInterval : Nat = _getRewardInterval(lastRewardTime, nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _rewardPerTime);
            accPerShare := Nat.add(accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _totalDeposit));
        };

        var _userInfo : Types.UserInfo = _getUserInfo(caller);
        var pending : Nat = Nat.sub(Nat.div(Nat.mul(_userInfo.amount, accPerShare), _arithmeticFactor), _userInfo.rewardDebt);
        if (pending == 0 or pending < _rewardTokenFee) {
            return;
        };
        var rewardAmount = pending;
        let rewardFee : Nat = Nat.div(Nat.mul(rewardAmount, initArgs.rewardFee), 1000);
        if (rewardFee > 0) {
            _totalRewardFee += rewardFee;
            rewardAmount := rewardAmount - rewardFee;
        };

        if (rewardAmount < _rewardTokenFee) {
            _totalRewardFee -= rewardFee;
            return;
        };

        _ledgerAmount.harvest += Float.div(_natToFloat(Nat.sub(rewardAmount, _rewardTokenFee)), Float.pow(10, _natToFloat(_rewardTokenDecimals)));
        _rewardDebt := _rewardDebt + pending;
        accPerShare := accPerShare;
        lastRewardTime := lastRewardTime;
        _userInfo.rewardDebt := Nat.div(Nat.mul(_userInfo.amount, accPerShare), _arithmeticFactor);
        _userInfo.lastRewardTime := lastRewardTime;
        _userInfoMap.put(caller, _userInfo);
        var _harvestRecord = {
            from = Principal.fromActor(this);
            to = caller;
            rewardStandard = _rewardToken.standard;
            rewardToken = _rewardToken.address;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            stakingStandard = _stakingToken.standard;
            stakingToken = _stakingToken.address;
            stakingTokenDecimals = _stakingTokenDecimals;
            stakingTokenSymbol = _stakingTokenSymbol;
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
        _preRewardRecordBuffer.add(trans);
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
