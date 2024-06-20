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
import CollectionUtils "mo:commons/utils/CollectionUtils";
import Types "./Types";

shared (initMsg) actor class Index(factoryId : Principal) = this {

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

    private stable var _users : [(Principal, [UserPool])] = [];
    private var _userMap : HashMap.HashMap<Principal, Buffer.Buffer<UserPool>> = HashMap.HashMap<Principal, Buffer.Buffer<UserPool>>(0, Principal.equal, Principal.hash);

    system func preupgrade() {
        let buffer = Buffer.Buffer<(Principal, [UserPool])>(_userMap.size());
        for ((key, value) in _userMap.entries()) {
            buffer.add((key, Buffer.toArray(value)));
        };
        _users := Buffer.toArray(buffer);
    };
    system func postupgrade() {
        for ((key, value) in _users.vals()) {
            _userMap.put(key, Buffer.fromArray<UserPool>(value));
        };
        _users := [];
    };

    public shared func query_pool(user : Principal, offset : Nat, limit : Nat, stakingToken : ?Text, rewardToken : ?Text) : async Result.Result<Types.Page<UserPool>, Types.Page<UserPool>> {
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

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    private func _syncUserInfo() : async () {
        let _syncResult = await _syncStakerFromPool();
    };

    public type IStakingPoolFactory = actor {
        findStakingPoolPage : shared query (state : ?Nat, offset : Nat, limit : Nat) -> async Result.Result<Types.Page<(Types.StakingPoolInfo)>, Types.Page<(Types.StakingPoolInfo)>>;
    };

    private var _syncStakerErrorMsg = "";

    private func _syncStakerFromPool() : async Bool {
        let length = 2000;
        let stakingPoolFactory = actor (Principal.toText(factoryId)) : IStakingPoolFactory;
        let pageResult = await stakingPoolFactory.findStakingPoolPage(null, 0, 1000);
        switch (pageResult) {
            case (#ok(page)) {
                for (stakingPool in page.content.vals()) {
                    let stakingPoolCanister = actor (Principal.toText(stakingPool.canisterId)) : Types.IStakingPool;
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
                                    begin += length;
                                    syncLength += userPage.content.size();
                                    totalLength := userPage.totalElements;
                                    if (syncLength >= totalLength) {
                                        whileState := false;
                                    };
                                };
                                case (#err(message)) {
                                    _syncStakerErrorMsg := "Sync Staker failed at " # debug_show (_getTime()) # ". Code: " # debug_show (message) # ". Stake pool id: " # debug_show (stakingPool.canisterId);
                                };
                            };
                        } catch (e) {
                            _syncStakerErrorMsg := "Sync Staker throw exception at " # debug_show (_getTime()) # ". Code: " # debug_show (Error.message(e)) # ". Stake pool id: " # debug_show (stakingPool.canisterId);
                            break whileLabel;
                        };
                        syncMaxTimes -= 1;
                    };
                };
            };
            case (#err(err)) {

            };
        };
        true;
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _checkPermission(caller : Principal) {
        assert (Prim.isController(caller));
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };

    var _syncUserInfoId : Timer.TimerId = Timer.recurringTimer<system>(#seconds(600), _syncUserInfo);
};
