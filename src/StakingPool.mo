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
import Hash "mo:base/Hash";

import CollectionUtils "mo:commons/utils/CollectionUtils";

import TokenFactory "mo:token-adapter/TokenFactory";

import Types "Types";

shared (initMsg) actor class StakingPool(initArgs : Types.InitRequests) : async Types.IStakingPool = this {

    private stable var _arithmeticFactor = 100_000_000_000_000_000_000;

    private stable var _rewardTokenFee = initArgs.rewardTokenFee;
    private stable var _rewardTokenSymbol = initArgs.rewardTokenSymbol;
    private stable var _rewardTokenDecimals = initArgs.rewardTokenDecimals;

    private stable var _stakingTokenFee = initArgs.stakingTokenFee;
    private stable var _stakingTokenSymbol = initArgs.stakingTokenSymbol;
    private stable var _stakingTokenDecimals = initArgs.stakingTokenDecimals;

    private stable var _rewardPerTime = initArgs.rewardPerTime;
    private stable var _startTime = initArgs.startTime;
    private stable var _bonusEndTime = initArgs.bonusEndTime;
    private stable var _lastRewardTime = initArgs.startTime;

    private stable var _accPerShare = 0;
    private stable var _rewardDebt = 0;
    private stable var _totalDeposit = 0;

    private stable var _totalRewardFee = 0;
    private stable var _receivedRewardFee = 0;

    private stable var _totalStaked = 0.0;
    private stable var _totalUnstaked = 0.0;
    private stable var _totalHarvest = 0.0;

    private stable var _liquidationStatus : Types.LiquidationStatus = #pending;

    private stable var _userInfoList : [(Principal, Types.UserInfo)] = [];
    private var _userInfoMap = HashMap.fromIter<Principal, Types.UserInfo>(_userInfoList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _stakingRecords : [Types.Record] = [];
    private var _stakingRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);

    private stable var _rewardRecords : [Types.Record] = [];
    private var _rewardRecordBuffer : Buffer.Buffer<Types.Record> = Buffer.Buffer<Types.Record>(0);

    private stable var _preTransfers : [(Nat, Types.Record)] = [];
    private var _preTransferMap : HashMap.HashMap<Nat, Types.Record> = HashMap.fromIter<Nat, Types.Record>(_preTransfers.vals(), 0, Nat.equal, Hash.hash);
    private stable var _preTransferIndex : Nat = 0;

    private let _userIndexActor = actor (Principal.toText(initArgs.userIndexCid)) : Types.IUserIndex;

    system func preupgrade() {
        _userInfoList := Iter.toArray(_userInfoMap.entries());
        _stakingRecords := Buffer.toArray(_stakingRecordBuffer);
        _rewardRecords := Buffer.toArray(_rewardRecordBuffer);
        _preTransfers := Iter.toArray(_preTransferMap.entries());
    };
    system func postupgrade() {
        _userInfoList := [];
        for (record in _stakingRecords.vals()) {
            _stakingRecordBuffer.add(record);
        };
        for (record in _rewardRecords.vals()) {
            _rewardRecordBuffer.add(record);
        };
        _stakingRecords := [];
        _rewardRecords := [];
        _preTransfers := [];
    };

    public shared (msg) func stop() : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        let now = _getTime();
        if (_bonusEndTime > now) {
            _bonusEndTime := now;
        };
        Timer.cancelTimer(_updateTokenInfoId);
        return _getPoolInfo();
    };

    public shared (msg) func updateStakingPool(params : Types.UpdateStakingPool) : async Result.Result<Types.PublicStakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);

        let now = _getTime();
        if (_bonusEndTime <= now) {
            Timer.cancelTimer(_updateTokenInfoId);
        };
        let _harvestAmount = _harvest(Principal.fromText("aaaaa-aa"));
        _lastRewardTime := now;
        _startTime := params.startTime;
        _bonusEndTime := params.bonusEndTime;
        _rewardPerTime := params.rewardPerTime;

        if (_bonusEndTime > now) {
            _updateTokenInfoId := Timer.recurringTimer<system>(#seconds(600), _updateTokenInfo);
        };
        return _getPoolInfo();
    };

    public shared (msg) func liquidation() : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

        let nowTime = _getTime();
        if (_bonusEndTime > nowTime) {
            return #err("Staking pool is unfinished");
        };

        label l for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            var liquidationAmount = userInfo.stakeAmount;

            if (liquidationAmount == 0) {
                continue l;
            };

            let _harvestAmount = _harvest(userPrincipal);

            let record = {
                to = userPrincipal;
                from = Principal.fromActor(this);
                rewardStandard = initArgs.rewardToken.standard;
                rewardToken = initArgs.rewardToken.address;
                rewardTokenDecimals = _rewardTokenDecimals;
                rewardTokenSymbol = _rewardTokenSymbol;
                stakingToken = initArgs.stakingToken.address;
                stakingStandard = initArgs.stakingToken.standard;
                stakingTokenSymbol = _stakingTokenSymbol;
                stakingTokenDecimals = _stakingTokenDecimals;
                amount = liquidationAmount;
                timestamp = nowTime;
                transType = #liquidate;
                transTokenType = #stakeToken;
                errMsg = "";
                result = "success";
            };

            _saveRecord(record);

            _totalUnstaked += Float.div(_natToFloat(liquidationAmount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
            _totalDeposit := Nat.sub(_totalDeposit, liquidationAmount);

            userInfo.stakeTokenBalance := Nat.add(userInfo.stakeTokenBalance, liquidationAmount);
            userInfo.stakeAmount := Nat.sub(userInfo.stakeAmount, liquidationAmount);
            userInfo.rewardDebt := Nat.div(
                Nat.mul(userInfo.stakeAmount, _accPerShare),
                _arithmeticFactor,
            );
            _userInfoMap.put(userPrincipal, userInfo);
            let publicUserInfo = _convert2PubUserInfo(userPrincipal, userInfo);
            ignore _userIndexActor.updateUser(userPrincipal, publicUserInfo);
        };
        _liquidationStatus := #liquidation;
        return #ok("Settle successfully");
    };

    public shared (msg) func refundUserToken() : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

        let nowTime = _getTime();

        if (_bonusEndTime > nowTime) {
            return #err("Staking pool is unfinished");
        };

        if (_liquidationStatus == #pending) {
            return #err("The staking pool has not been liquidated yet");
        };

        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            if (userInfo.stakeTokenBalance >= _stakingTokenFee) {
                let _result = await _withdraw(userPrincipal, true, userInfo.stakeTokenBalance);
            };
            if (userInfo.rewardTokenBalance >= _rewardTokenFee) {
                let _result = await _withdraw(userPrincipal, false, userInfo.rewardTokenBalance);
            };
        };
        _liquidationStatus := #liquidated;
        return #ok("Refund successfully");
    };

    public shared (msg) func refundRewardToken() : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

        let nowTime = _getTime();

        if (_bonusEndTime > nowTime) {
            return #err("Staking pool is unfinished");
        };

        if (_liquidationStatus != #liquidated) {
            return #err("The staking pool has not been liquidated yet");
        };

        var poolCanisterId = Principal.fromActor(this);
        let tokenAdapter = TokenFactory.getAdapter(initArgs.rewardToken.address, initArgs.rewardToken.standard);
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

        var transAmount : Nat = Nat.sub(balance, _rewardTokenFee);
        switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = initArgs.feeReceiverCid; subaccount = null }; amount = transAmount; fee = ?_rewardTokenFee; memo = null; created_at_time = null })) {
            case (#Ok(index)) {
                return #ok("Refund successfully");
            };
            case (#Err(message)) {
                return #err("Refund error:" #debug_show (message));
            };
        };
    };

    public query (msg) func findTransferRecord() : async Result.Result<[(Nat, Types.Record)], Types.Error> {
        _checkAdminPermission(msg.caller);
        return #ok(Iter.toArray(_preTransferMap.entries()));
    };

    public shared (msg) func removeTransferRecord(index : Nat, rollback : Bool) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        switch (_preTransferMap.get(index)) {
            case (?record) {
                if (Text.equal("error", record.result)) {
                    let userPrincipal = if (record.transType == #withdraw) {
                        record.to;
                    } else {
                        record.from;
                    };
                    if (record.transTokenType == #stakeToken) {
                        if (rollback) {
                            var userInfo = _getUserInfo(userPrincipal);
                            userInfo.stakeTokenBalance := Nat.add(userInfo.stakeTokenBalance, record.amount);
                            _userInfoMap.put(userPrincipal, userInfo);
                            let publicUserInfo = _convert2PubUserInfo(userPrincipal, userInfo);
                            ignore _userIndexActor.updateUser(userPrincipal, publicUserInfo);
                        };
                    } else {
                        if (rollback) {
                            var userInfo = _getUserInfo(userPrincipal);
                            userInfo.rewardTokenBalance := Nat.add(userInfo.rewardTokenBalance, record.amount);
                            _userInfoMap.put(userPrincipal, userInfo);
                            let publicUserInfo = _convert2PubUserInfo(userPrincipal, userInfo);
                            ignore _userIndexActor.updateUser(userPrincipal, publicUserInfo);
                        };
                    };
                    _removePreTransfer(index);
                } else {
                    return #err("Not an error record");
                };
            };
            case (_) {
                return #err("Record not found");
            };
        };
        return #ok(true);
    };

    public query (msg) func unclaimdRewardFee() : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        return #ok(Nat.sub(_totalRewardFee, _receivedRewardFee));
    };

    public shared (msg) func withdrawRewardFee() : async Result.Result<Text, Text> {
        assert (Principal.equal(msg.caller, initArgs.feeReceiverCid));

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(initArgs.rewardToken.address, initArgs.rewardToken.standard);
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
            if (pending <= _rewardTokenFee) {
                return #err("The unclaimd reward token fee of pool is less than the reward token transfer fee");
            };

            var amount : Nat = Nat.sub(pending, _rewardTokenFee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = null }; from_subaccount = null; to = { owner = initArgs.feeReceiverCid; subaccount = null }; amount = amount; fee = ?_rewardTokenFee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    _receivedRewardFee += pending;
                    return #ok("Withdraw successfully");
                };
                case (#Err(message)) {
                    return #err("Withdraw error:" #debug_show (message));
                };
            };
        } catch (e) {
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func deposit() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let nowTime = _getTime();
        if (_startTime > nowTime or _bonusEndTime < nowTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(initArgs.stakingToken.standard, "ICP") and Text.notEqual(initArgs.stakingToken.standard, "ICRC1") and Text.notEqual(initArgs.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (initArgs.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        var poolCanisterId = Principal.fromActor(this);
        let tokenAdapter = TokenFactory.getAdapter(initArgs.stakingToken.address, initArgs.stakingToken.standard);
        var balance : Nat = await tokenAdapter.balanceOf({
            owner = poolCanisterId;
            subaccount = subaccount;
        });
        if (balance <= _stakingTokenFee) {
            return #err("The deposit amount is less than the transfer fee of the staking token");
        };
        var depositAmount : Nat = Nat.sub(balance, _stakingTokenFee);

        let record = {
            from = msg.caller;
            to = Principal.fromActor(this);
            rewardStandard = initArgs.rewardToken.standard;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardToken = initArgs.rewardToken.address;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            amount = depositAmount;
            timestamp = nowTime;
            transType = #deposit;
            transTokenType = #stakeToken;
            errMsg = "";
            result = "processing";
        };
        let index = _preTransfer(record);

        try {
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = poolCanisterId; subaccount = null }; amount = depositAmount; fee = ?_stakingTokenFee; memo = Option.make(Types.natToBlob(index)); created_at_time = null })) {
                case (#Ok(txIndex)) {
                    var userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    userInfo.stakeTokenBalance := Nat.add(userInfo.stakeTokenBalance, depositAmount);
                    _userInfoMap.put(msg.caller, userInfo);
                    _postTransferComplete(index);

                    let publicUserInfo = _convert2PubUserInfo(msg.caller, userInfo);
                    ignore _userIndexActor.updateUser(msg.caller, publicUserInfo);
                    return #ok("Deposit successfully");
                };
                case (#Err(message)) {
                    let msg = "Deposit failed at " # debug_show (_getTime()) # ". Code: " # debug_show (message) # ". Deposit info: " # debug_show (record);
                    _postTransferError(index, msg);
                    return #err("Deposit error:" #debug_show (message));
                };
            };
        } catch (e) {
            let msg = "Deposit throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Deposit info: " # debug_show (record);
            _postTransferError(index, msg);
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func depositFrom(amount : Nat) : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let nowTime = _getTime();
        if (_startTime > nowTime or _bonusEndTime < nowTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(initArgs.stakingToken.standard, "ICP") and Text.notEqual(initArgs.stakingToken.standard, "ICRC1") and Text.notEqual(initArgs.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (initArgs.stakingToken.standard));
        };

        let tokenAdapter = TokenFactory.getAdapter(initArgs.stakingToken.address, initArgs.stakingToken.standard);
        var balance : Nat = await tokenAdapter.balanceOf({
            owner = msg.caller;
            subaccount = null;
        });
        if (amount > balance) {
            return #err("Insufficient balance");
        };
        if (amount <= _stakingTokenFee) {
            return #err("The deposit amount is less than the transfer fee of the staking token");
        };
        var depositAmount : Nat = Nat.sub(amount, _stakingTokenFee);

        var poolCanisterId = Principal.fromActor(this);

        var record = {
            from = msg.caller;
            to = Principal.fromActor(this);
            rewardStandard = initArgs.rewardToken.standard;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardToken = initArgs.rewardToken.address;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            amount = depositAmount;
            timestamp = nowTime;
            transType = #deposit;
            transTokenType = #stakeToken;
            errMsg = "";
            result = "processing";
        };
        let index = _preTransfer(record);
        try {
            switch (await tokenAdapter.transferFrom({ from = { owner = msg.caller; subaccount = null }; to = { owner = poolCanisterId; subaccount = null }; amount = depositAmount; fee = ?_stakingTokenFee; memo = Option.make(Types.natToBlob(index)); created_at_time = null })) {
                case (#Ok(txIndex)) {
                    var userInfo : Types.UserInfo = _getUserInfo(msg.caller);
                    userInfo.stakeTokenBalance := Nat.add(userInfo.stakeTokenBalance, depositAmount);
                    _userInfoMap.put(msg.caller, userInfo);
                    _postTransferComplete(index);

                    let publicUserInfo = _convert2PubUserInfo(msg.caller, userInfo);
                    ignore _userIndexActor.updateUser(msg.caller, publicUserInfo);
                    return #ok("Deposit successfully");
                };
                case (#Err(message)) {
                    let msg = "Deposit failed at " # debug_show (_getTime()) # ". Code: " # debug_show (message) # ". Deposit info: " # debug_show (record);
                    _postTransferError(index, msg);
                    return #err("Deposit error:" #debug_show (message));
                };
            };
        } catch (e) {
            let msg = "Deposit throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Deposit info: " # debug_show (record);
            _postTransferError(index, msg);
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    public shared (msg) func stake() : async Result.Result<Nat, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        let nowTime = _getTime();
        if (_startTime > nowTime or _bonusEndTime < nowTime) {
            return #err("Staking pool is not available for now");
        };
        if (Text.notEqual(initArgs.stakingToken.standard, "ICP") and Text.notEqual(initArgs.stakingToken.standard, "ICRC1") and Text.notEqual(initArgs.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (initArgs.stakingToken.standard));
        };

        let harvestAmount = _harvest(msg.caller);

        let userInfo = _getUserInfo(msg.caller);
        let stakeAmount = userInfo.stakeTokenBalance;
        if (stakeAmount <= 0) {
            return #err("The amount of stake can't be 0");
        };

        let record = {
            from = msg.caller;
            to = Principal.fromActor(this);
            rewardStandard = initArgs.rewardToken.standard;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardToken = initArgs.rewardToken.address;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            amount = stakeAmount;
            timestamp = nowTime;
            transType = #stake;
            transTokenType = #stakeToken;
            errMsg = "";
            result = "success";
        };
        _saveRecord(record);

        _totalStaked += Float.div(_natToFloat(stakeAmount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
        if (_totalDeposit == 0) {
            _lastRewardTime := nowTime;
        };
        _totalDeposit := Nat.add(_totalDeposit, stakeAmount);

        userInfo.stakeTokenBalance := Nat.sub(userInfo.stakeTokenBalance, stakeAmount);
        userInfo.stakeAmount := Nat.add(userInfo.stakeAmount, stakeAmount);
        userInfo.rewardDebt := Nat.div(
            Nat.mul(userInfo.stakeAmount, _accPerShare),
            _arithmeticFactor,
        );
        userInfo.lastStakeTime := nowTime;
        _userInfoMap.put(msg.caller, userInfo);
        let publicUserInfo = _convert2PubUserInfo(msg.caller, userInfo);
        ignore _userIndexActor.updateUser(msg.caller, publicUserInfo);
        return #ok(harvestAmount);
    };

    public shared (msg) func unstake(amount : Nat) : async Result.Result<Nat, Text> {
        var userInfo : Types.UserInfo = _getUserInfo(msg.caller);
        var unstakeAmount = if (amount > userInfo.stakeAmount) {
            userInfo.stakeAmount;
        } else {
            amount;
        };
        if (unstakeAmount == 0) {
            return #err("The amount of unstake can't be 0");
        };

        let harvestAmount = _harvest(msg.caller);

        let nowTime = _getTime();
        var record = {
            to = msg.caller;
            from = Principal.fromActor(this);
            rewardStandard = initArgs.rewardToken.standard;
            rewardToken = initArgs.rewardToken.address;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardTokenSymbol = _rewardTokenSymbol;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            amount = unstakeAmount;
            timestamp = nowTime;
            transType = #unstake;
            transTokenType = #stakeToken;
            errMsg = "";
            result = "success";
        };
        _saveRecord(record);

        _totalUnstaked += Float.div(_natToFloat(unstakeAmount), Float.pow(10, _natToFloat(_stakingTokenDecimals)));
        _totalDeposit := Nat.sub(_totalDeposit, unstakeAmount);

        userInfo.stakeTokenBalance := Nat.add(userInfo.stakeTokenBalance, unstakeAmount);
        userInfo.stakeAmount := Nat.sub(userInfo.stakeAmount, unstakeAmount);
        userInfo.rewardDebt := Nat.div(
            Nat.mul(userInfo.stakeAmount, _accPerShare),
            _arithmeticFactor,
        );
        _userInfoMap.put(msg.caller, userInfo);

        let publicUserInfo = _convert2PubUserInfo(msg.caller, userInfo);
        ignore _userIndexActor.updateUser(msg.caller, publicUserInfo);
        return #ok(harvestAmount);
    };

    public shared (msg) func harvest() : async Result.Result<Nat, Text> {
        try {
            let harvestAmount = _harvest(msg.caller);
            var userInfo : Types.UserInfo = _getUserInfo(msg.caller);
            let publicUserInfo = _convert2PubUserInfo(msg.caller, userInfo);
            ignore _userIndexActor.updateUser(msg.caller, publicUserInfo);
            return #ok(harvestAmount);
        } catch (e) {
            return #err("Harvest throw exception: " #debug_show (Error.message(e)));
        };
    };

    public shared (msg) func withdraw(isStakeToken : Bool, amount : Nat) : async Result.Result<Text, Text> {
        try {
            return await _withdraw(msg.caller, isStakeToken, amount);
        } catch (e) {
            return #err("Withdraw throw exception: " #debug_show (Error.message(e)));
        };
    };

    public shared (msg) func claim() : async Result.Result<Text, Text> {
        if (Principal.isAnonymous(msg.caller)) return #err("Illegal anonymous call");
        if (Text.notEqual(initArgs.stakingToken.standard, "ICP") and Text.notEqual(initArgs.stakingToken.standard, "ICRC1") and Text.notEqual(initArgs.stakingToken.standard, "ICRC2")) {
            return #err("Illegal token standard: " # debug_show (initArgs.stakingToken.standard));
        };
        var subaccount : ?Blob = Option.make(Types.principalToBlob(msg.caller));
        if (null == subaccount) {
            return #err("Subaccount can't be null");
        };

        try {
            var poolCanisterId = Principal.fromActor(this);
            let tokenAdapter = TokenFactory.getAdapter(initArgs.stakingToken.address, initArgs.stakingToken.standard);
            var balance : Nat = await tokenAdapter.balanceOf({
                owner = poolCanisterId;
                subaccount = subaccount;
            });
            if (balance <= _stakingTokenFee) {
                return #err("The claim amount is less than the transfer fee of the staking token");
            };
            var amount : Nat = Nat.sub(balance, _stakingTokenFee);
            switch (await tokenAdapter.transfer({ from = { owner = poolCanisterId; subaccount = subaccount }; from_subaccount = subaccount; to = { owner = msg.caller; subaccount = null }; amount = amount; fee = ?_stakingTokenFee; memo = null; created_at_time = null })) {
                case (#Ok(index)) {
                    return #ok("Claim successfully");
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

    public query func findUserInfo(offset : Nat, limit : Nat) : async Result.Result<Types.Page<(Principal, Types.PublicUserInfo)>, Text> {
        let size = _userInfoMap.size();
        if (size == 0) {
            return #ok({
                totalElements = 0;
                content = [];
                offset = offset;
                limit = limit;
            });
        };

        var buffer : Buffer.Buffer<(Principal, Types.PublicUserInfo)> = Buffer.Buffer<(Principal, Types.PublicUserInfo)>(_userInfoMap.size());
        for ((userPrincipal, userInfo) in _userInfoMap.entries()) {
            buffer.add((
                userPrincipal,
                {
                    stakeTokenBalance = userInfo.stakeTokenBalance;
                    rewardTokenBalance = userInfo.rewardTokenBalance;
                    stakeAmount = userInfo.stakeAmount;
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
        let userInfo = _getUserInfo(user);
        return #ok({
            stakeTokenBalance = userInfo.stakeTokenBalance;
            rewardTokenBalance = userInfo.rewardTokenBalance;
            stakeAmount = userInfo.stakeAmount;
            rewardDebt = userInfo.rewardDebt;
            pendingReward = _pendingReward(user);
            lastRewardTime = userInfo.lastRewardTime;
            lastStakeTime = userInfo.lastStakeTime;
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
        let stakingRecords = CollectionUtils.sort<Types.Record>(
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
            totalElements = stakingRecords.size();
            content = CollectionUtils.arrayRange<Types.Record>(stakingRecords, offset, limit);
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
        let rewardRecords = CollectionUtils.sort<Types.Record>(
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
            totalElements = rewardRecords.size();
            content = CollectionUtils.arrayRange<Types.Record>(rewardRecords, offset, limit);
            offset = offset;
            limit = limit;
        });
    };

    private func _getPoolInfo() : Result.Result<Types.PublicStakingPoolInfo, Text> {
        return #ok({
            name = initArgs.name;

            rewardToken = initArgs.rewardToken;
            rewardTokenFee = _rewardTokenFee;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;

            stakingToken = initArgs.stakingToken;
            stakingTokenFee = _stakingTokenFee;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;

            startTime = _startTime;
            bonusEndTime = _bonusEndTime;
            rewardPerTime = _rewardPerTime;
            rewardFee = initArgs.rewardFee;
            feeReceiverCid = initArgs.feeReceiverCid;

            creator = initArgs.creator;
            createTime = initArgs.createTime;

            lastRewardTime = _lastRewardTime;
            accPerShare = _accPerShare;
            totalDeposit = _totalDeposit;
            rewardDebt = _rewardDebt;

            totalHarvest = _totalHarvest;
            totalStaked = _totalStaked;
            totalUnstaked = _totalUnstaked;

            liquidationStatus = _liquidationStatus;
        });
    };

    private func _updateTokenInfo() : async () {
        let stakingTokenAdapter = TokenFactory.getAdapter(
            initArgs.stakingToken.address,
            initArgs.stakingToken.standard,
        );
        _stakingTokenFee := await stakingTokenAdapter.fee();
        _stakingTokenDecimals := Nat8.toNat(await stakingTokenAdapter.decimals());
        _stakingTokenSymbol := await stakingTokenAdapter.symbol();

        let rewardTokenAdapter = TokenFactory.getAdapter(
            initArgs.rewardToken.address,
            initArgs.rewardToken.standard,
        );
        _rewardTokenFee := await rewardTokenAdapter.fee();
        _rewardTokenDecimals := Nat8.toNat(await rewardTokenAdapter.decimals());
        _rewardTokenSymbol := await rewardTokenAdapter.symbol();
    };

    private func _getUserInfo(user : Principal) : Types.UserInfo {
        switch (_userInfoMap.get(user)) {
            case (?userInfo) {
                userInfo;
            };
            case (_) {
                {
                    var stakeTokenBalance = 0;
                    var rewardTokenBalance = 0;
                    var stakeAmount = 0;
                    var rewardDebt = 0;
                    var lastStakeTime = 0;
                    var lastRewardTime = 0;
                };
            };
        };
    };

    private func _withdraw(to : Principal, isStakeToken : Bool, amount : Nat) : async Result.Result<Text, Text> {
        var userInfo : Types.UserInfo = _getUserInfo(to);
        var withdrawAmountWithFee = amount;
        var withdrawAmount = amount;
        var withdrawTokenType : Types.TransTokenType = #stakeToken;
        var withdrawToken = initArgs.stakingToken;
        if (not isStakeToken) {
            withdrawTokenType := #rewardToken;
            withdrawToken := initArgs.rewardToken;
        };
        if (isStakeToken) {
            if (amount > userInfo.stakeTokenBalance) {
                withdrawAmountWithFee := userInfo.stakeTokenBalance;
            };
            if (withdrawAmountWithFee < _stakingTokenFee) {
                return #err("The withdraw amount is less than the transfer fee of the staking token");
            } else {
                withdrawAmount := Nat.sub(withdrawAmountWithFee, _stakingTokenFee);
            };
        } else {
            if (amount > userInfo.rewardTokenBalance) {
                withdrawAmountWithFee := userInfo.rewardTokenBalance;
            };
            if (withdrawAmountWithFee < _rewardTokenFee) {
                return #err("The withdraw amount is less than the transfer fee of the reward token");
            } else {
                withdrawAmount := Nat.sub(withdrawAmountWithFee, _rewardTokenFee);
            };
        };

        if (withdrawAmountWithFee == 0) {
            return #err("The withdraw amount can't be 0");
        };

        let tokenAdapter = TokenFactory.getAdapter(withdrawToken.address, withdrawToken.standard);
        var balance : Nat = await tokenAdapter.balanceOf({
            owner = Principal.fromActor(this);
            subaccount = null;
        });

        if (balance < withdrawAmountWithFee) {
            return #err("Insufficient token balance to be withdrawn");
        };

        if (isStakeToken) {
            userInfo.stakeTokenBalance := Nat.sub(userInfo.stakeTokenBalance, withdrawAmountWithFee);
        } else {
            userInfo.rewardTokenBalance := Nat.sub(userInfo.rewardTokenBalance, withdrawAmountWithFee);
        };

        let nowTime = _getTime();
        var record = {
            to = to;
            from = Principal.fromActor(this);
            rewardStandard = initArgs.rewardToken.standard;
            rewardToken = initArgs.rewardToken.address;
            rewardTokenDecimals = _rewardTokenDecimals;
            rewardTokenSymbol = _rewardTokenSymbol;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenSymbol = _stakingTokenSymbol;
            stakingTokenDecimals = _stakingTokenDecimals;
            amount = withdrawAmountWithFee;
            timestamp = nowTime;
            transType = #withdraw;
            transTokenType = withdrawTokenType;
            errMsg = "";
            result = "processing";
        };
        let index = _preTransfer(record);
        _userInfoMap.put(to, userInfo);

        let publicUserInfo = _convert2PubUserInfo(to, userInfo);
        ignore _userIndexActor.updateUser(to, publicUserInfo);

        try {

            switch (await tokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = to; subaccount = null }; fee = null; amount = withdrawAmount; memo = Option.make(Types.natToBlob(index)); created_at_time = null })) {
                case (#Ok(txIndex)) {
                    _postTransferComplete(index);
                    return #ok("Withdraw successfully");
                };
                case (#Err(code)) {
                    let msg = "Withdraw failed at " # debug_show (_getTime()) # ". Code: " # debug_show (code) # ". Withdraw info: " # debug_show (record);
                    _postTransferError(index, msg);
                    return #err("Withdraw error:" #debug_show (code));
                };
            };
        } catch (e) {
            let msg = "Withdraw throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Withdraw info: " # debug_show (record);
            _postTransferError(index, msg);
            return #err("InternalError: " # (debug_show (Error.message(e))));
        };
    };

    private func _harvest(caller : Principal) : Nat {
        let rewardAmount : Nat = _pendingReward(caller);
        if (rewardAmount == 0) {
            return 0;
        };
        //update pool info
        var nowTime = _getTime();
        if (nowTime <= _lastRewardTime) { return 0 };
        _lastRewardTime := nowTime;
        _totalHarvest += Float.div(_natToFloat(rewardAmount), Float.pow(10, _natToFloat(_rewardTokenDecimals)));
        _rewardDebt := _rewardDebt + rewardAmount;

        //update user info
        var userInfo : Types.UserInfo = _getUserInfo(caller);
        userInfo.rewardTokenBalance := Nat.add(userInfo.rewardTokenBalance, rewardAmount);
        userInfo.rewardDebt := Nat.div(Nat.mul(userInfo.stakeAmount, _accPerShare), _arithmeticFactor);
        userInfo.lastRewardTime := nowTime;
        _userInfoMap.put(caller, userInfo);

        //add harvest record
        var record = {
            from = Principal.fromActor(this);
            to = caller;
            rewardStandard = initArgs.rewardToken.standard;
            rewardToken = initArgs.rewardToken.address;
            rewardTokenSymbol = _rewardTokenSymbol;
            rewardTokenDecimals = _rewardTokenDecimals;
            stakingStandard = initArgs.stakingToken.standard;
            stakingToken = initArgs.stakingToken.address;
            stakingTokenDecimals = _stakingTokenDecimals;
            stakingTokenSymbol = _stakingTokenSymbol;
            amount = rewardAmount;
            timestamp = nowTime;
            transType = #harvest;
            transTokenType = #rewardToken;
            errMsg = "";
            result = "success";
        };
        _saveRecord(record);
        return rewardAmount;
    };

    private func _pendingReward(user : Principal) : Nat {
        var nowTime = _getTime();
        var userInfo : Types.UserInfo = _getUserInfo(user);
        if (nowTime > _lastRewardTime and _totalDeposit != 0) {
            var rewardInterval : Nat = _getRewardInterval(nowTime);
            var reward : Nat = Nat.mul(rewardInterval, _rewardPerTime);
            _accPerShare := Nat.add(_accPerShare, Nat.div(Nat.mul(reward, _arithmeticFactor), _totalDeposit));
        };
        var rewardAmount = Nat.sub(Nat.div(Nat.mul(userInfo.stakeAmount, _accPerShare), _arithmeticFactor), userInfo.rewardDebt);
        let rewardFee : Nat = Nat.div(Nat.mul(rewardAmount, initArgs.rewardFee), 1000);
        if (rewardFee > 0) {
            rewardAmount := rewardAmount - rewardFee;
        };
        if (rewardAmount > 0 and rewardFee > 0 and rewardAmount >= _rewardTokenFee) {
            _totalRewardFee += rewardFee;
        };

        return rewardAmount;
    };

    private func _getRewardInterval(nowTime : Nat) : Nat {
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

    private func _preTransfer(preRecord : Types.Record) : Nat {
        let transferIndex : Nat = _preTransferIndex;
        _preTransferMap.put(transferIndex, preRecord);
        _preTransferIndex := _preTransferIndex + 1;
        return transferIndex;
    };

    private func _postTransferComplete(index : Nat) {
        switch (_preTransferMap.get(index)) {
            case (?record) {
                _saveRecord({ record with errMsg = ""; result = "success" });
            };
            case (_) {};
        };
        _removePreTransfer(index);
    };

    private func _postTransferError(index : Nat, msg : Text) {
        switch (_preTransferMap.get(index)) {
            case (?record) {
                _preTransferMap.put(index, { record with errMsg = msg; result = "error" });
            };
            case (_) {};
        };
    };

    private func _removePreTransfer(index : Nat) {
        _preTransferMap.delete(index);
    };

    private func _natToFloat(amount : Nat) : Float {
        Float.fromInt(amount);
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _convert2PubUserInfo(userPrincipal : Principal, userInfo : Types.UserInfo) : Types.PublicUserInfo {
        let publicUserInfo = {
            stakeTokenBalance = userInfo.stakeTokenBalance;
            rewardTokenBalance = userInfo.rewardTokenBalance;
            stakeAmount = userInfo.stakeAmount;
            rewardDebt = userInfo.rewardDebt;
            pendingReward = 0;
            lastRewardTime = userInfo.lastRewardTime;
            lastStakeTime = userInfo.lastStakeTime;
        };
        return publicUserInfo;
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

    var _updateTokenInfoId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _updateTokenInfo);

    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };
};
