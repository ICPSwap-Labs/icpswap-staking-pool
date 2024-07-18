import Prim "mo:⛔";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";
import Timer "mo:base/Timer";
import HashMap "mo:base/HashMap";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Time "mo:base/Time";
import Error "mo:base/Error";
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";
import Bool "mo:base/Bool";
import Iter "mo:base/Iter";
import Float "mo:base/Float";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import IntUtils "mo:commons/math/SafeInt/IntUtils";
import Types "./Types";
import TokenPriceHelper "TokenPriceHelper";

shared (initMsg) actor class StakingPoolIndex(factoryId : Principal) = this {

    public type UserPool = {
        stakingPool : Principal;
        stakingToken : Types.Token;
        rewardToken : Types.Token;
        owner : Principal;
        userInfo : Types.PublicUserInfo;
    };

    public type APRInfo = Types.APRInfo;

    private func _userPoolEqual(a : UserPool, b : UserPool) : Bool {
        Principal.equal(a.stakingPool, b.stakingPool);
    };

    private stable var _syncStakingPoolTime = 0;
    private stable var _computeStakingPoolTime = 0;

    private stable var _pools : [(Principal, Types.StakingPoolInfo)] = [];
    private var _poolMap = HashMap.fromIter<Principal, Types.StakingPoolInfo>(_pools.vals(), 10, Principal.equal, Principal.hash);

    private stable var _users : [(Principal, [UserPool])] = [];
    private var _userMap : HashMap.HashMap<Principal, Buffer.Buffer<UserPool>> = HashMap.HashMap<Principal, Buffer.Buffer<UserPool>>(0, Principal.equal, Principal.hash);

    private stable var _aprs : [(Principal, [Types.APRInfo])] = [];
    private var _aprMap : HashMap.HashMap<Principal, Buffer.Buffer<Types.APRInfo>> = HashMap.HashMap<Principal, Buffer.Buffer<Types.APRInfo>>(0, Principal.equal, Principal.hash);

    system func preupgrade() {
        _pools := Iter.toArray(_poolMap.entries());
        let buffer = Buffer.Buffer<(Principal, [UserPool])>(_userMap.size());
        for ((key, value) in _userMap.entries()) {
            buffer.add((key, Buffer.toArray(value)));
        };
        _users := Buffer.toArray(buffer);
        let aprBuffer = Buffer.Buffer<(Principal, [Types.APRInfo])>(_aprMap.size());
        for ((key, value) in _aprMap.entries()) {
            aprBuffer.add((key, Buffer.toArray(value)));
        };
        _aprs := Buffer.toArray(aprBuffer);
    };
    system func postupgrade() {
        _pools := [];
        for ((key, value) in _users.vals()) {
            _userMap.put(key, Buffer.fromArray<UserPool>(value));
        };
        _users := [];
        for ((key, value) in _aprs.vals()) {
            _aprMap.put(key, Buffer.fromArray<Types.APRInfo>(value));
        };
        _aprs := [];
    };

    public query func queryPool(user : Principal, offset : Nat, limit : Nat, stakingToken : ?Text, rewardToken : ?Text) : async Result.Result<Types.Page<UserPool>, Types.Page<UserPool>> {
        let buffer = Buffer.Buffer<UserPool>(10);
        let now = _getTime();
        switch (_userMap.get(user)) {
            case (?userBuffer) {
                for (userPool in userBuffer.vals()) {
                    var addBuffer = false;
                    if (Option.isNull(stakingToken) and Option.isNull(rewardToken)) {
                        addBuffer := true;
                    } else {
                        switch (stakingToken) {
                            case (?stakingToken) {
                                if (Text.equal(userPool.stakingToken.address, stakingToken)) {
                                    addBuffer := true;
                                };
                            };
                            case (_) {};
                        };
                        switch (rewardToken) {
                            case (?rewardToken) {
                                if (Text.equal(userPool.rewardToken.address, rewardToken)) {
                                    addBuffer := true;
                                };
                            };
                            case (_) {};
                        };
                    };
                    if (addBuffer) {
                        switch (_poolMap.get(userPool.stakingPool)) {
                            case (?pool) {
                                if ((pool.startTime <= now and pool.bonusEndTime >= now) or
                                 (userPool.userInfo.stakeAmount > 0 or userPool.userInfo.rewardTokenBalance > 0 or userPool.userInfo.stakeTokenBalance > 0)) {
                                    buffer.add(userPool);
                                };
                            };
                            case (_) {};
                        };
                    };
                };
            };
            case (_) {};
        };
        if (buffer.size() > 0) {
            return #ok({
                totalElements = buffer.size();
                content = CollectionUtils.arrayRange<UserPool>(Buffer.toArray(buffer), offset, limit);
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

    public query func queryStakingPool(offset : Nat, limit : Nat) : async Result.Result<Types.Page<Types.StakingPoolInfo>, Text> {
        let buffer = Buffer.Buffer<Types.StakingPoolInfo>(10);
        for ((canister, pool) in _poolMap.entries()) {
            buffer.add(pool);
        };
        if (buffer.size() > 0) {
            return #ok({
                totalElements = buffer.size();
                content = CollectionUtils.arrayRange<Types.StakingPoolInfo>(Buffer.toArray(buffer), offset, limit);
                offset = offset;
                limit = limit;
            });
        } else {
            return #err("No staking pool");
        };
    };

    public query func queryIndexInfo() : async Result.Result<(Nat, Nat, Principal), Text> {
        return #ok(_syncStakingPoolTime, _computeStakingPoolTime, factoryId);
    };

    public shared (msg) func syncStakingPool() : async Result.Result<Nat, Text> {
        _checkPermission(msg.caller);
        await _syncStakingPool();
        return #ok(_poolMap.size());
    };

    public shared (msg) func computeStakingPool() : async Result.Result<Nat, Text> {
        _checkPermission(msg.caller);
        await _computeStakingPool();
        return #ok(_poolMap.size());
    };

    public query func queryAPR(pool : Principal, beginTime : Nat, endTime : Nat) : async Result.Result<[Types.APRInfo], Text> {
        let buffer = Buffer.Buffer<Types.APRInfo>(10);
        switch (_aprMap.get(pool)) {
            case (?aprBuffer) {
                for (aprInfo in aprBuffer.vals()) {
                    var addBuffer = false;
                    if (aprInfo.time >= beginTime and aprInfo.time <= endTime) {
                        addBuffer := true;
                    };
                    if (addBuffer) {
                        buffer.add(aprInfo);
                    };
                };
            };
            case (_) {};
        };
        return #ok(Buffer.toArray(buffer));
    };

    public shared ({ caller }) func updateUser(userPrincipal : Principal, userInfo : Types.PublicUserInfo) : async Result.Result<Bool, Text> {
        try {
            switch (_poolMap.get(caller)) {
                case (?stakingPool) {
                    _updateUser(userPrincipal, userInfo, stakingPool);
                };
                case (_) {
                    let stakingPoolFactory = actor (Principal.toText(factoryId)) : Types.IStakingPoolFactory;
                    switch (await stakingPoolFactory.getStakingPool(caller)) {
                        case (#ok(stakingPool)) {
                            _poolMap.put(caller, stakingPool);
                            _updateUser(userPrincipal, userInfo, stakingPool);
                        };
                        case (#err(message)) {
                            return #err(message);
                        };
                    };
                };
            };
        } catch (e) {
            return #err(Error.message(e));
        };
        return #ok(true);
    };

    private func _updateUser(userPrincipal : Principal, userInfo : Types.PublicUserInfo, stakingPool : Types.StakingPoolInfo) {
        let userPool = {
            stakingPool = stakingPool.canisterId;
            stakingToken = stakingPool.stakingToken;
            rewardToken = stakingPool.rewardToken;
            owner = userPrincipal;
            userInfo = userInfo;
        };
        switch (_userMap.get(userPrincipal)) {
            case (?userBuffer) {
                switch (Buffer.indexOf<UserPool>(userPool, userBuffer, _userPoolEqual)) {
                    case (?index) {
                        userBuffer.put(index, userPool);
                    };
                    case (_) {
                        userBuffer.add(userPool);
                    };
                };
                _userMap.put(userPrincipal, userBuffer);
            };
            case (_) {
                var userBuffer = Buffer.Buffer<UserPool>(1);
                userBuffer.add(userPool);
                _userMap.put(userPrincipal, userBuffer);
            };
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    private func _syncStakingPool() : async () {
        let stakingPoolFactory = actor (Principal.toText(factoryId)) : Types.IStakingPoolFactory;
        let pageResult = await stakingPoolFactory.findStakingPoolPage(null, 0, 1000);
        switch (pageResult) {
            case (#ok(page)) {
                let _newPoolMap = HashMap.HashMap<Principal, Types.StakingPoolInfo>(page.content.size(), Principal.equal, Principal.hash);
                for (stakingPool in page.content.vals()) {
                    _newPoolMap.put(stakingPool.canisterId, stakingPool);
                };
                if(_newPoolMap.size() > 0){
                    _poolMap := _newPoolMap;
                };
                _syncStakingPoolTime := _getTime();
            };
            case (#err(err)) {

            };
        };
    };

    private func _computeStakingPool() : async () {
        let now = _getTime();
        _computeStakingPoolTime := now;
        var tokenPrice = TokenPriceHelper.TokenPrice(null);
        await tokenPrice.syncToken2ICPPrice();
        for ((key, stakingPool) in _poolMap.entries()) {
            if (stakingPool.startTime <= now and stakingPool.bonusEndTime > now) {
                let stakingPoolActor = actor (Principal.toText(key)) : Types.IStakingPool;
                let result = await stakingPoolActor.getPoolInfo();
                switch (result) {
                    case (#ok(stakingPoolInfo)) {
                        let rewardPerTime = stakingPoolInfo.rewardPerTime;
                        let stakingTokenAmount = Float.sub(stakingPoolInfo.totalStaked, stakingPoolInfo.totalUnstaked);
                        let rewardTokenPriceUSD = tokenPrice.getToken2USDPrice(stakingPoolInfo.rewardToken.address);
                        let stakingTokenPriceUSD = tokenPrice.getToken2USDPrice(stakingPoolInfo.stakingToken.address);
                        //APR=(rewardPerTime*rewardTokenPriceUSD)/(stakingTokenAmount*stakingTokenPriceUSD)*3600*24*360*100%
                        let rewardValuePerTime : Float = Float.mul(
                            Float.mul(
                                Float.fromInt(IntUtils.toInt(rewardPerTime, 256)),
                                Float.fromInt(IntUtils.toInt(Nat.pow(10, stakingPool.rewardTokenDecimals), 256)),
                            ),
                            rewardTokenPriceUSD,
                        );
                        let stakingValue : Float = Float.mul(stakingTokenAmount, stakingTokenPriceUSD);
                        var apr : Float = 0;
                        if (Float.greater(stakingValue, 0)) {
                            apr := Float.mul(Float.mul(Float.div(rewardValuePerTime, stakingValue), Float.fromInt(3600 * 24)), Float.fromInt(360));
                        };
                        let aprInfo : Types.APRInfo = {
                            stakingPool = key;
                            time = now;
                            day = Nat.add(Nat.div(now, 86400), 1);
                            apr = apr;
                            rewardPerTime = rewardPerTime;
                            stakingTokenAmount = stakingTokenAmount;
                            rewardTokenDecimals = stakingPoolInfo.rewardTokenDecimals;
                            stakingTokenDecimals = stakingPoolInfo.stakingTokenDecimals;
                            rewardTokenPriceUSD = rewardTokenPriceUSD;
                            stakingTokenPriceUSD = stakingTokenPriceUSD;
                        };
                        switch (_aprMap.get(key)) {
                            case (?buffer) {
                                buffer.add(aprInfo);
                                _aprMap.put(key, buffer);
                            };
                            case (_) {
                                let buffer = Buffer.Buffer<Types.APRInfo>(1);
                                buffer.add(aprInfo);
                                _aprMap.put(key, buffer);
                            };
                        };
                    };
                    case (#err(err)) {

                    };
                };
            };
        };
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _checkPermission(caller : Principal) {
        assert (Prim.isController(caller));
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "1.0.1";
    public query func getVersion() : async Text { _version };

    var _syncStakingPoolId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(60), _syncStakingPool);
    var _computeStakingPoolId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _computeStakingPool);
};
