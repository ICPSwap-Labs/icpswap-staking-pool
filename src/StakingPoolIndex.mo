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
import CollectionUtils "mo:commons/utils/CollectionUtils";
import Types "./Types";

shared (initMsg) actor class StakingPoolIndex(factoryId : Principal) = this {

    public type UserPool = {
        stakingPool : Principal;
        stakingToken : Types.Token;
        rewardToken : Types.Token;
        owner : Principal;
        userInfo : Types.PublicUserInfo;
    };

    private func _userPoolEqual(a : UserPool, b : UserPool) : Bool {
        Principal.equal(a.stakingPool, b.stakingPool);
    };

    private stable var _pools : [(Principal, Types.StakingPoolInfo)] = [];
    private var _poolMap : HashMap.HashMap<Principal, Types.StakingPoolInfo> = HashMap.HashMap<Principal, Types.StakingPoolInfo>(0, Principal.equal, Principal.hash);

    private stable var _users : [(Principal, [UserPool])] = [];
    private var _userMap : HashMap.HashMap<Principal, Buffer.Buffer<UserPool>> = HashMap.HashMap<Principal, Buffer.Buffer<UserPool>>(0, Principal.equal, Principal.hash);

    system func preupgrade() {
        _pools := Iter.toArray(_poolMap.entries());
        let buffer = Buffer.Buffer<(Principal, [UserPool])>(_userMap.size());
        for ((key, value) in _userMap.entries()) {
            buffer.add((key, Buffer.toArray(value)));
        };
        _users := Buffer.toArray(buffer);
    };
    system func postupgrade() {
        _pools := [];
        for ((key, value) in _users.vals()) {
            _userMap.put(key, Buffer.fromArray<UserPool>(value));
        };
        _users := [];
    };

    public query func queryPool(user : Principal, offset : Nat, limit : Nat, stakingToken : ?Text, rewardToken : ?Text) : async Result.Result<Types.Page<UserPool>, Types.Page<UserPool>> {
        let buffer = Buffer.Buffer<UserPool>(10);

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
                        buffer.add(userPool);
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
                for (stakingPool in page.content.vals()) {
                    _poolMap.put(stakingPool.canisterId, stakingPool);
                };
            };
            case (#err(err)) {

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

    var _syncUserInfoId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _syncStakingPool);
};
