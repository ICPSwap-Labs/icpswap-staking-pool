import Prim "mo:⛔";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Bool "mo:base/Bool";
import Timer "mo:base/Timer";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Float "mo:base/Float";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";
import List "mo:base/List";

import IC0 "mo:commons/utils/IC0Utils";
import ListUtil "mo:commons/utils/ListUtils";
import IntUtils "mo:commons/math/SafeInt/IntUtils";
import CollectionUtils "mo:commons/utils/CollectionUtils";

import Types "Types";
import StakingPool "StakingPool";
import TokenPriceHelper "TokenPriceHelper";

shared (initMsg) actor class StakingPoolFactory(
    feeReceiverCid : Principal,
    governanceCid : ?Principal,
) = this {

    private stable var _valueOfStaking : Float = 0;
    private stable var _valueOfRewardsInProgress : Float = 0;
    private stable var _valueOfRewarded : Float = 0;
    private stable var _totalPools : Nat = 0;
    private stable var _totalStaker : Nat = 0;

    private var _initCycles : Nat = 1860000000000;
    private stable var _rewardFee : Nat = 50;

    private stable var _stakingPoolList : [(Principal, Types.StakingPoolInfo)] = [];
    private var _stakingPoolMap = HashMap.fromIter<Principal, Types.StakingPoolInfo>(_stakingPoolList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _stakingPoolStatList : [(Principal, Types.TokenGlobalDataState)] = [];
    private var _stakingPoolStatMap = HashMap.fromIter<Principal, Types.TokenGlobalDataState>(_stakingPoolStatList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _stakerList : [(Principal, Types.PublicUserInfo)] = [];
    private var _stakerMap = HashMap.fromIter<Principal, Types.PublicUserInfo>(_stakerList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _syncStakerErrorMsg = "";
    private stable var _updateGlobalDataErrorMsg = "";

    private stable var _timeToUpdateGlobalData = 0;
    private stable var _timeToSyncStaker = 0;

    private stable var _userIndexCid : Principal = Principal.fromText("aaaaa-aa");

    private var _updateStakingPoolsGlobalDataState = true;

    system func preupgrade() {
        _stakingPoolList := Iter.toArray(_stakingPoolMap.entries());
        _stakingPoolStatList := Iter.toArray(_stakingPoolStatMap.entries());
        _stakerList := Iter.toArray(_stakerMap.entries());
    };
    system func postupgrade() {
        _stakingPoolList := [];
        _stakingPoolStatList := [];
        _stakerList := [];
    };

    public shared (msg) func stopTimer() : async () {
        _checkAdminPermission(msg.caller);
        Timer.cancelTimer(_updateStakingPoolsGlobalDataId);
    };

    public shared (msg) func setRewardFee(rewardFee : Nat) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _rewardFee := rewardFee;
        return #ok(true);
    };

    public shared (msg) func setUpdateGlobalDataState(state : Bool) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _updateStakingPoolsGlobalDataState := state;
        return #ok(true);
    };

    public shared (msg) func setUserIndexCanister(cid : Principal) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _userIndexCid := cid;
        return #ok(true);
    };

    public shared (msg) func createStakingPool(params : Types.InitRequest) : async Result.Result<Principal, Text> {
        _checkAdminPermission(msg.caller);

        if (Principal.equal(_userIndexCid, Principal.fromText("aaaaa-aa"))) {
            return #err("UserIndexCanister is not set");
        };

        let balance = Cycles.balance();
        if (balance < (4 * _initCycles)) {
            return #err("Insufficient controller cycle balance");
        };
        Cycles.add<system>(_initCycles);
        let requests : Types.InitRequests = {
            params with rewardFee = _rewardFee;
            feeReceiverCid = feeReceiverCid;
            creator = msg.caller;
            createTime = _getTime();
            userIndexCid = _userIndexCid;
        };
        let stakingPool = await StakingPool.StakingPool(requests);
        let stakingPoolCanister : Principal = Principal.fromActor(stakingPool);
        switch (governanceCid) {
            case (?cid) {
                await IC0.update_settings_add_controller(stakingPoolCanister, cid);
            };
            case (_) {
                await IC0.update_settings_add_controller(stakingPoolCanister, initMsg.caller);
            };
        };
        var stakingPoolInfo : Types.StakingPoolInfo = _initParamToStakingPoolInfo(params, msg.caller, stakingPoolCanister);
        _stakingPoolMap.put(stakingPoolCanister, stakingPoolInfo);
        return #ok(stakingPoolInfo.canisterId);
    };

    public shared (msg) func setStakingPoolTime(poolCanister : Principal, startTime : Nat, bonusEndTime : Nat) : async Result.Result<Types.StakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        switch (_stakingPoolMap.get(poolCanister)) {
            case (?stakingPoolInfo) {
                let stakingPoolCanister = actor (Principal.toText(poolCanister)) : Types.IStakingPool;
                switch (await stakingPoolCanister.updateStakingPool({ startTime = startTime; bonusEndTime = bonusEndTime; rewardPerTime = stakingPoolInfo.rewardPerTime })) {
                    case (#ok(publicStakingPoolInfo)) {
                        var newStakingPoolInfo : Types.StakingPoolInfo = _publicStakingPoolToStakingPoolInfo(publicStakingPoolInfo, stakingPoolInfo);
                        _stakingPoolMap.put(poolCanister, newStakingPoolInfo);
                        return #ok(newStakingPoolInfo);
                    };
                    case (#err(message)) {
                        return #err(message);
                    };
                };
            };
            case (_) {};
        };
        return #err("Staking pool does not exist");
    };

    public shared (msg) func stopStakingPool(poolCanister : Principal) : async Result.Result<Types.StakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        switch (_stakingPoolMap.get(poolCanister)) {
            case (?stakingPoolInfo) {
                let stakingPoolCanister = actor (Principal.toText(poolCanister)) : Types.IStakingPool;
                switch (await stakingPoolCanister.stop()) {
                    case (#ok(publicStakingPoolInfo)) {
                        var newStakingPoolInfo : Types.StakingPoolInfo = _publicStakingPoolToStakingPoolInfo(publicStakingPoolInfo, stakingPoolInfo);
                        _stakingPoolMap.put(poolCanister, newStakingPoolInfo);
                        return #ok(newStakingPoolInfo);
                    };
                    case (#err(message)) {
                        return #err(message);
                    };
                };
            };
            case (_) {};
        };
        return #err("Staking pool does not exist");
    };

    public shared (msg) func deleteStakingPool(poolCanister : Principal) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _stakingPoolMap.delete(poolCanister);
        return #ok(true);
    };

    public shared (msg) func unclaimdRewardFee(poolCanister : Principal) : async Result.Result<Nat, Text> {
        _checkAdminPermission(msg.caller);
        let stakingPoolCanister = actor (Principal.toText(poolCanister)) : Types.IStakingPool;
        await stakingPoolCanister.unclaimdRewardFee();
    };

    public query func getInitArgs() : async Result.Result<{ feeReceiverCid : Principal; governanceCid : ?Principal; userIndexCid : Principal }, Types.Error> {
        #ok({
            feeReceiverCid = feeReceiverCid;
            governanceCid = governanceCid;
            userIndexCid = _userIndexCid;
        });
    };

    public query func getStakingPool(poolCanisterId : Principal) : async Result.Result<Types.StakingPoolInfo, Text> {
        switch (_stakingPoolMap.get(poolCanisterId)) {
            case (?poolCanister) {
                return #ok(poolCanister);
            };
            case (null) {
                return #err("Not found");
            };
        };
    };

    //1.no start,2.ongoing,3.ended
    public query func findStakingPoolPage(state : ?Nat, offset : Nat, limit : Nat) : async Result.Result<Types.Page<(Types.StakingPoolInfo)>, Types.Page<(Types.StakingPoolInfo)>> {
        var buffer : Buffer.Buffer<(Types.StakingPoolInfo)> = Buffer.Buffer<(Types.StakingPoolInfo)>(_stakingPoolMap.size());
        var reqState : Nat = 0;
        var reqStateState : Bool = false;
        if (not Option.isNull(state)) {
            reqStateState := true;
            reqState := Option.get(state, 0);
        };
        let currentTime = _getTime();
        var addBuffer = false;
        for ((stakingPoolCanister, stakingPoolInfo) in _stakingPoolMap.entries()) {
            Debug.print("findStakingPoolPage debug: " # debug_show (stakingPoolInfo));
            addBuffer := false;
            if (reqStateState) {
                if (reqState == 1) {
                    Debug.print("findStakingPoolPage debug: " # debug_show (reqStateState) # " and " # debug_show (reqState));
                    if (stakingPoolInfo.startTime > currentTime) {
                        addBuffer := true;
                    };
                } else if (reqState == 2) {
                    if (stakingPoolInfo.startTime <= currentTime and stakingPoolInfo.bonusEndTime > currentTime) {
                        addBuffer := true;
                    };
                } else if (reqState == 3) {
                    if (stakingPoolInfo.startTime < currentTime and stakingPoolInfo.bonusEndTime <= currentTime) {
                        addBuffer := true;
                    };
                };
            } else {
                addBuffer := true;
            };
            if (addBuffer) {
                buffer.add(stakingPoolInfo);
            };
        };
        if (buffer.size() > 0) {
            return #ok({
                totalElements = buffer.size();
                content = CollectionUtils.arrayRange<Types.StakingPoolInfo>(Buffer.toArray(buffer), offset, limit);
                offset = offset;
                limit = limit;
            });
        };
        return #ok({
            totalElements = 0;
            content = [];
            offset = offset;
            limit = limit;
        });
    };

    //1.no start,2.ongoing,3.ended
    public query func findStakingPoolPageV2(state : ?Nat, offset : Nat, limit : Nat, stakingToken : ?Text, rewardToken : ?Text) : async Result.Result<Types.Page<(Types.StakingPoolInfo)>, Types.Page<(Types.StakingPoolInfo)>> {
        var buffer : Buffer.Buffer<(Types.StakingPoolInfo)> = Buffer.Buffer<(Types.StakingPoolInfo)>(_stakingPoolMap.size());
        var reqState : Nat = 0;
        var reqStateCheck : Bool = false;
        if (not Option.isNull(state)) {
            reqStateCheck := true;
            reqState := Option.get(state, 0);
        };
        var stakingTokenLedger = "";
        var rewardTokenLedger = "";
        switch (stakingToken) {
            case (?stakingToken) {
                reqStateCheck := true;
                stakingTokenLedger := stakingToken;
            };
            case (_) {};
        };
        switch (rewardToken) {
            case (?rewardToken) {
                reqStateCheck := true;
                rewardTokenLedger := rewardToken;
            };
            case (_) {};
        };
        let currentTime = _getTime();
        for ((stakingPoolCanister, stakingPoolInfo) in _stakingPoolMap.entries()) {
            Debug.print("findStakingPoolPage debug: " # debug_show (stakingPoolInfo));
            var addBuffer = true;
            if (reqStateCheck) {
                if (reqState == 1) {
                    Debug.print("findStakingPoolPage debug: " # debug_show (reqStateCheck) # " and " # debug_show (reqState));
                    if (stakingPoolInfo.startTime <= currentTime) {
                        addBuffer := false;
                    };
                } else if (reqState == 2) {
                    if (stakingPoolInfo.startTime > currentTime or stakingPoolInfo.bonusEndTime <= currentTime) {
                        addBuffer := false;
                    };
                } else if (reqState == 3) {
                    if (stakingPoolInfo.startTime >= currentTime or stakingPoolInfo.bonusEndTime > currentTime) {
                        addBuffer := false;
                    };
                };
                if (stakingTokenLedger != "" and not Text.equal(stakingPoolInfo.stakingToken.address, stakingTokenLedger)){
                    addBuffer := false;
                };
                if (rewardTokenLedger != "" and not Text.equal(stakingPoolInfo.rewardToken.address, rewardTokenLedger)) {
                    addBuffer := false;
                };
            };
            if (addBuffer) {
                buffer.add(stakingPoolInfo);
            };
        };
        if (buffer.size() > 0) {
            return #ok({
                totalElements = buffer.size();
                content = CollectionUtils.arrayRange<Types.StakingPoolInfo>(Buffer.toArray(buffer), offset, limit);
                offset = offset;
                limit = limit;
            });
        };
        return #ok({
            totalElements = 0;
            content = [];
            offset = offset;
            limit = limit;
        });
    };

    public query func getGlobalData() : async Result.Result<Types.GlobalDataInfo, Text> {
        var stakingAmount : Float = 0;
        var rewardAmount : Float = 0;
        for ((id, stat) in _stakingPoolStatMap.entries()) {
            stakingAmount := Float.add(stat.stakingAmount, stakingAmount);
            rewardAmount := Float.add(stat.rewardAmount, rewardAmount);
        };
        return #ok({
            valueOfStaking = _valueOfStaking;
            valueOfRewardsInProgress = _valueOfRewardsInProgress;
            valueOfRewarded = _valueOfRewarded;
            totalPools = _stakingPoolMap.size();
            totalStaker = _totalStaker;
        });
    };

    public query func getPoolStatInfo(stakingPoolCanisterId : Principal) : async Result.Result<Types.TokenGlobalDataInfo, Text> {
        switch (_stakingPoolStatMap.get(stakingPoolCanisterId)) {
            case (?stat) {
                #ok({
                    stakingTokenCanisterId = stat.stakingTokenCanisterId;
                    stakingTokenAmount = stat.stakingTokenAmount;
                    stakingTokenPrice = stat.stakingTokenPrice;
                    stakingAmount = stat.stakingAmount;
                    rewardTokenCanisterId = stat.rewardTokenCanisterId;
                    rewardTokenAmount = stat.rewardTokenAmount;
                    rewardTokenPrice = stat.rewardTokenPrice;
                    rewardAmount = stat.rewardAmount;
                });
            };
            case (null) {
                #err("Not found");
            };
        };
    };

    public query func findPoolStatInfo() : async Result.Result<[Types.TokenGlobalDataInfo], Text> {
        var buffer : Buffer.Buffer<Types.TokenGlobalDataInfo> = Buffer.Buffer<Types.TokenGlobalDataInfo>(_stakingPoolStatMap.size());
        for ((id, stat) in _stakingPoolStatMap.entries()) {
            buffer.add({
                stakingTokenCanisterId = stat.stakingTokenCanisterId;
                stakingTokenAmount = stat.stakingTokenAmount;
                stakingTokenPrice = stat.stakingTokenPrice;
                stakingAmount = stat.stakingAmount;
                rewardTokenCanisterId = stat.rewardTokenCanisterId;
                rewardTokenAmount = stat.rewardTokenAmount;
                rewardTokenPrice = stat.rewardTokenPrice;
                rewardAmount = stat.rewardAmount;
            });
        };
        return #ok(Buffer.toArray(buffer));
    };

    public query func getOperationInfo() : async Result.Result<(Text, Text, Nat, Nat, Bool), Text> {
        return #ok(_updateGlobalDataErrorMsg, _syncStakerErrorMsg, _timeToUpdateGlobalData, _timeToSyncStaker, _updateStakingPoolsGlobalDataState);
    };

    public shared (msg) func setStakingPoolAdmins(stakingPoolCid : Principal, admins : [Principal]) : async () {
        _checkPermission(msg.caller);
        var stakingPoolAct = actor (Principal.toText(stakingPoolCid)) : Types.IStakingPool;
        await stakingPoolAct.setAdmins(admins);
    };

    private let IC = actor "aaaaa-aa" : actor {
        update_settings : { canister_id : Principal; settings : { controllers : [Principal]; } } -> ();
    };

    public shared (msg) func addStakingPoolControllers(stakingPoolCid : Principal, controllers : [Principal]) : async () {
        _checkPermission(msg.caller);
        let { settings } = await IC0.canister_status(stakingPoolCid);
        var controllerList = List.append(List.fromArray(settings.controllers), List.fromArray(controllers));
        IC.update_settings({ canister_id = stakingPoolCid; settings = { controllers = List.toArray(controllerList) }; });
    };

    public shared (msg) func removeStakingPoolControllers(stakingPoolCid : Principal, controllers : [Principal]) : async () {
        _checkPermission(msg.caller);
        if (_hasFactory(controllers)){
            throw Error.reject("StakingPoolFactory must be the controller of StakingPool.");
        };
        let { settings } = await IC0.canister_status(stakingPoolCid);
        let buffer: Buffer.Buffer<Principal> = Buffer.Buffer<Principal>(0);
        for (it in settings.controllers.vals()) {
            if (not CollectionUtils.arrayContains<Principal>(controllers, it, Principal.equal)) {
                buffer.add(it);
            };
        };
        IC.update_settings({ canister_id = stakingPoolCid; settings = { controllers = Buffer.toArray<Principal>(buffer) }; });
    };

    private func _hasFactory(controllers : [Principal]) : Bool {
        let controllerCid : Principal = Principal.fromActor(this);
        for (it in controllers.vals()) {
            if (Principal.equal(it, controllerCid)) {
                return true;
            };
        };
        false;
    };

    private func _initParamToStakingPoolInfo(params : Types.InitRequest, caller : Principal, stakingPoolCanister : Principal) : Types.StakingPoolInfo {
        let nowTime = _getTime();
        var stakingPoolInfo : Types.StakingPoolInfo = {
            creator = caller;
            rewardToken = params.rewardToken;
            rewardTokenSymbol = params.rewardTokenSymbol;
            rewardTokenDecimals = params.rewardTokenDecimals;
            rewardTokenFee = params.rewardTokenFee;
            name = params.name;
            canisterId = stakingPoolCanister;
            createTime = nowTime;
            startTime = params.startTime;
            bonusEndTime = params.bonusEndTime;
            stakingToken = params.stakingToken;
            stakingTokenSymbol = params.stakingTokenSymbol;
            stakingTokenDecimals = params.stakingTokenDecimals;
            stakingTokenFee = params.stakingTokenFee;
            rewardPerTime = params.rewardPerTime;
        };
        return stakingPoolInfo;
    };

    private func _publicStakingPoolToStakingPoolInfo(params : Types.PublicStakingPoolInfo, poolInfo : Types.StakingPoolInfo) : Types.StakingPoolInfo {
        var stakingPoolInfo : Types.StakingPoolInfo = {
            rewardToken = params.rewardToken;
            rewardTokenSymbol = params.rewardTokenSymbol;
            rewardTokenDecimals = params.rewardTokenDecimals;
            rewardTokenFee = params.rewardTokenFee;
            stakingToken = params.stakingToken;
            stakingTokenSymbol = params.stakingTokenSymbol;
            stakingTokenDecimals = params.stakingTokenDecimals;
            stakingTokenFee = params.stakingTokenFee;

            name = poolInfo.name;
            canisterId = poolInfo.canisterId;
            creator = poolInfo.creator;
            createTime = poolInfo.createTime;
            startTime = params.startTime;
            bonusEndTime = params.bonusEndTime;
            rewardPerTime = params.rewardPerTime;
        };
        return stakingPoolInfo;
    };

    private func _updateStakingPoolsGlobalData() : async () {
        if (not _updateStakingPoolsGlobalDataState) return;
        _updateStakingPoolsGlobalDataState := false;
        let beginTime = _getTime();
        try {
            var valueOfStaking : Float = 0;
            var valueOfRewardsInProgress : Float = 0;
            var valueOfRewarded : Float = 0;
            var tokenPrice = TokenPriceHelper.TokenPrice(null);
            await tokenPrice.syncToken2ICPPrice();
            label forLabel for ((stakingPoolCanisterId, stakingPool) in _stakingPoolMap.entries()) {
                try {
                    var totalRewardAmount = 0;
                    var totalStakingAmount = 0;
                    var bonusEndTime = stakingPool.bonusEndTime;
                    var rewardPerTime = stakingPool.rewardPerTime;
                    var startTime = stakingPool.startTime;
                    let stakingPoolCanister = actor (Principal.toText(stakingPoolCanisterId)) : Types.IStakingPool;
                    switch (await stakingPoolCanister.getPoolInfo()) {
                        case (#ok(poolInfo)) {
                            totalStakingAmount := poolInfo.totalDeposit;
                            bonusEndTime := poolInfo.bonusEndTime;
                            rewardPerTime := poolInfo.rewardPerTime;
                            startTime := poolInfo.startTime;
                            totalRewardAmount := rewardPerTime * (bonusEndTime - startTime);
                        };
                        case (#err(code)) {};
                    };
                    var rewardTokenIcpPrice : Float = tokenPrice.getToken2ICPPrice(stakingPool.rewardToken.address);
                    let rewardAmount : Float = Float.div(
                        Float.fromInt(IntUtils.toInt(totalRewardAmount, 256)),
                        Float.fromInt(IntUtils.toInt(Nat.pow(10, stakingPool.rewardTokenDecimals), 256)),
                    );
                    var tokenRewardAmountVaule = Float.mul(
                        rewardAmount,
                        rewardTokenIcpPrice,
                    );
                    var stakingTokenIcpPrice : Float = tokenPrice.getToken2ICPPrice(stakingPool.stakingToken.address);
                    let stakingAmount : Float = Float.div(
                        Float.fromInt(IntUtils.toInt(totalStakingAmount, 256)),
                        Float.fromInt(IntUtils.toInt(Nat.pow(10, stakingPool.stakingTokenDecimals), 256)),
                    );
                    var tokenStakingAmountValue = Float.mul(
                        stakingAmount,
                        stakingTokenIcpPrice,
                    );
                    if (beginTime > bonusEndTime) {
                        valueOfRewarded += tokenRewardAmountVaule;
                    } else {
                        valueOfRewardsInProgress += tokenRewardAmountVaule;
                        //Only the total amount of staking in the Live status
                        valueOfStaking += tokenStakingAmountValue;
                    };

                    var stakingPoolGlobalStat = {
                        var stakingTokenCanisterId = stakingPool.stakingToken.address;
                        var stakingTokenAmount = totalStakingAmount;
                        var stakingTokenPrice = stakingTokenIcpPrice;
                        var stakingAmount = tokenStakingAmountValue;
                        var rewardTokenCanisterId = stakingPool.rewardToken.address;
                        var rewardTokenAmount = totalRewardAmount;
                        var rewardTokenPrice = rewardTokenIcpPrice;
                        var rewardAmount = tokenRewardAmountVaule;
                    };
                    _stakingPoolStatMap.put(stakingPoolCanisterId, stakingPoolGlobalStat);
                } catch (e) {
                    _updateGlobalDataErrorMsg := "Update global data throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Stake pool id: " # debug_show (stakingPoolCanisterId);
                    continue forLabel;
                };
            };
            let _result = await syncStakerFromPool();
            _valueOfStaking := valueOfStaking;
            _valueOfRewardsInProgress := valueOfRewardsInProgress;
            _valueOfRewarded := valueOfRewarded;
            _totalPools := _stakingPoolMap.size();
            _totalStaker := _stakerMap.size();
        } catch (e) {
            _updateGlobalDataErrorMsg := "Update global data throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e));
        };
        let endTime = _getTime();
        _timeToUpdateGlobalData := endTime - beginTime;
        _updateStakingPoolsGlobalDataState := true;
    };

    private func syncStakerFromPool() : async Bool {
        let beginTime = _getTime();
        let length = 2000;
        for ((stakingPoolCanisterId, stakingPool) in _stakingPoolMap.entries()) {
            let stakingPoolCanister = actor (Principal.toText(stakingPoolCanisterId)) : Types.IStakingPool;
            var whileState = true;
            var syncLength = 0;
            var totalLength = 0;
            var syncMaxTimes = 100;
            var begin = 0;
            label whileLabel while (whileState and syncMaxTimes > 0) {
                try {
                    switch (await stakingPoolCanister.findUserInfo(begin, length)) {
                        case (#ok(userPage)) {
                            for ((userPrincipal, userInfo) in userPage.content.vals()) {
                                _stakerMap.put(userPrincipal, userInfo);
                            };
                            begin += length;
                            syncLength += userPage.content.size();
                            totalLength := userPage.totalElements;
                            if (syncLength >= totalLength) {
                                whileState := false;
                            };
                        };
                        case (#err(message)) {
                            _syncStakerErrorMsg := "Sync Staker failed at " # debug_show (_getTime()) # ". Code: " # debug_show (message) # ". Stake pool id: " # debug_show (stakingPoolCanisterId);
                        };
                    };
                } catch (e) {
                    _syncStakerErrorMsg := "Sync Staker throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Stake pool id: " # debug_show (stakingPoolCanisterId);
                    break whileLabel;
                };
                syncMaxTimes -= 1;
            };
        };
        let endTime = _getTime();
        _timeToSyncStaker := endTime - beginTime;
        true;
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
        return (ListUtil.arrayContains<Principal>(_admins, caller, Principal.equal) or _hasPermission(caller));
    };

    private func _checkPermission(caller : Principal) {
        assert (_hasPermission(caller));
    };

    private func _hasPermission(caller : Principal) : Bool {
        return Prim.isController(caller) or (switch (governanceCid) { case (?cid) { Principal.equal(caller, cid) }; case (_) { false } });
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    let _updateStakingPoolsGlobalDataId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _updateStakingPoolsGlobalData);
    private var _version : Text = "1.0.2";
    public query func getVersion() : async Text { _version };
};
