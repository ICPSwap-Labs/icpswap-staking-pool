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

import IC0 "mo:commons/utils/IC0Utils";
import ListUtil "mo:commons/utils/ListUtils";
import IntUtils "mo:commons/math/SafeInt/IntUtils";
import CollectionUtils "mo:commons/utils/CollectionUtils";

import Types "Types";
import StakingPool "StakingPool";

shared (initMsg) actor class StakingPoolController(
    feeReceiverCid : Principal,
    governanceCid : ?Principal,
) = this {

    private stable var _globalDataState : Types.GlobalDataState = {
        var stakingAmount : Float = 0;
        var rewardAmount : Float = 0;
    };

    private var _initCycles : Nat = 1860000000000;
    private stable var _rewardFee : Nat = 50;
    private stable var _tokenPriceCanisterId = "arfra-7aaaa-aaaag-qb2aq-cai";

    private stable var _stakingPoolList : [(Principal, Types.StakingPoolInfo)] = [];
    private var _stakingPoolMap = HashMap.fromIter<Principal, Types.StakingPoolInfo>(_stakingPoolList.vals(), 10, Principal.equal, Principal.hash);

    private stable var _stakingPoolStatList : [(Principal, Types.TokenGlobalDataState)] = [];
    private var _stakingPoolStatMap = HashMap.fromIter<Principal, Types.TokenGlobalDataState>(_stakingPoolStatList.vals(), 10, Principal.equal, Principal.hash);

    system func preupgrade() {
        _stakingPoolList := Iter.toArray(_stakingPoolMap.entries());
        _stakingPoolStatList := Iter.toArray(_stakingPoolStatMap.entries());
    };
    system func postupgrade() {
        _stakingPoolList := [];
        _stakingPoolStatList := [];
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

    public shared (msg) func setTokenPriceCanister(tokenPrice : Principal) : async Result.Result<Bool, Text> {
        _checkAdminPermission(msg.caller);
        _tokenPriceCanisterId := Principal.toText(tokenPrice);
        return #ok(true);
    };

    public shared (msg) func setStakingPoolTime(poolCanister : Principal, startTime : Nat, bonusEndTime : Nat) : async Result.Result<Types.StakingPoolInfo, Text> {
        _checkAdminPermission(msg.caller);
        switch (_stakingPoolMap.get(poolCanister)) {
            case (?stakingPoolInfo) {
                let stakingPoolCanister = actor (Principal.toText(poolCanister)) : Types.IStakingPool;
                switch (await stakingPoolCanister.setTime(startTime, bonusEndTime)) {
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

    public shared (msg) func createStakingPool(params : Types.InitRequest) : async Result.Result<Principal, Text> {
        _checkAdminPermission(msg.caller);
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

    public query func getInitArgs() : async Result.Result<{ feeReceiverCid : Principal; governanceCid : ?Principal }, Types.Error> {
        #ok({ feeReceiverCid = feeReceiverCid; governanceCid = governanceCid });
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

    public query func getGlobalData() : async Result.Result<Types.GlobalDataInfo, Text> {
        var stakingAmount : Float = 0;
        var rewardAmount : Float = 0;
        for ((id, stat) in _stakingPoolStatMap.entries()) {
            stakingAmount := Float.add(stat.stakingAmount, stakingAmount);
            rewardAmount := Float.add(stat.rewardAmount, rewardAmount);
        };
        return #ok({
            stakingAmount = stakingAmount;
            rewardAmount = rewardAmount;
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
            startTime = poolInfo.startTime;
            bonusEndTime = params.bonusEndTime;
            rewardPerTime = params.rewardPerTime;
        };
        return stakingPoolInfo;
    };

    private func _updateStakingPoolsGlobalData() : async () {
        var stakingAmountTmp : Float = 0;
        var rewardAmountTmp : Float = 0;
        var tokenPrice = Types.TokenPrice(?_tokenPriceCanisterId);
        for ((stakingPoolCanisterId, stakingPool) in _stakingPoolMap.entries()) {
            try {
                var totalRewardAmount = 0;
                var totalStakingAmount = 0;
                let stakingPoolCanister = actor (Principal.toText(stakingPoolCanisterId)) : Types.IStakingPool;
                switch (await stakingPoolCanister.getPoolInfo()) {
                    case (#ok(poolInfo)) {
                        totalStakingAmount := poolInfo.totalDeposit;
                        totalRewardAmount := poolInfo.rewardPerTime * (stakingPool.bonusEndTime - stakingPool.startTime);
                    };
                    case (#err(code)) {};
                };
                var zeroForOne = true;
                var rewardTokenIcpPrice : Float = await tokenPrice.getToken2ICPPrice(stakingPool.rewardToken.address, stakingPool.rewardToken.standard, stakingPool.rewardTokenDecimals);
                let rewardAmount : Float = Float.div(
                    Float.fromInt(IntUtils.toInt(totalRewardAmount, 256)),
                    Float.fromInt(IntUtils.toInt(Nat.pow(10, stakingPool.rewardTokenDecimals), 256)),
                );
                var tokenRewardAmountVaule = Float.mul(
                    rewardAmount,
                    rewardTokenIcpPrice,
                );
                rewardAmountTmp += tokenRewardAmountVaule;

                zeroForOne := true;
                var stakingTokenIcpPrice : Float = await tokenPrice.getToken2ICPPrice(stakingPool.stakingToken.address, stakingPool.stakingToken.standard, stakingPool.stakingTokenDecimals);
                let stakingAmount : Float = Float.div(
                    Float.fromInt(IntUtils.toInt(totalStakingAmount, 256)),
                    Float.fromInt(IntUtils.toInt(Nat.pow(10, stakingPool.stakingTokenDecimals), 256)),
                );
                var tokenStakingAmountValue = Float.mul(
                    stakingAmount,
                    stakingTokenIcpPrice,
                );
                stakingAmountTmp += tokenStakingAmountValue;
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
                Debug.print("err: " # Error.message(e));
            };
        };
        _globalDataState := {
            var stakingAmount = stakingAmountTmp;
            var rewardAmount = rewardAmountTmp;
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
    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };
};
