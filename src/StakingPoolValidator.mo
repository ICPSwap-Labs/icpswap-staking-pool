import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Time "mo:base/Time";
import Bool "mo:base/Bool";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import SafeUint "mo:commons/math/SafeUint";
import TokenFactory "mo:token-adapter/TokenFactory";
import Types "./Types";

shared (initMsg) actor class StakingPoolValidator(
    stakingPoolFactoryCid : Principal,
    governanceCid : Principal,
) = this {

    public type Result = {
        #Ok : Text;
        #Err : Text;
    };

    private stable var _initCycles : Nat = 1860000000000;

    private stable var _ONE_YEAR : Nat = 31557600;
    private stable var _SIX_MONTH : Nat = 15778800;
    private stable var _ONE_MONTH : Nat = 2629800;
    private stable var _ONE_WEEK : Nat = 604800;
    private stable var _TWELVE_HOURS : Nat = 43200;
    private stable var _FOUR_HOURS : Nat = 14400;
    private stable var _THIRTY_MINUTES : Nat = 1800;

    private var _stakingPoolFactoryAct = actor (Principal.toText(stakingPoolFactoryCid)) : Types.IStakingPoolFactory;

    public shared (msg) func createValidate(args : Types.InitRequest) : async Result {
        assert (Principal.equal(msg.caller, governanceCid));

        var nowTime = _getTime();
        if (args.rewardPerTime <= 0) {
            return #Err("Reward per time amount must be positive");
        };
        if (nowTime > args.startTime) {
            return #Err("Start time must be after current time");
        };
        if (args.startTime >= args.bonusEndTime) {
            return #Err("Start time must be before end time");
        };
        if ((SafeUint.Uint256(args.startTime).sub(SafeUint.Uint256(nowTime)).val()) > _ONE_MONTH) {
            return #Err("Start time is too far from current time");
        };
        var duration = SafeUint.Uint256(args.bonusEndTime).sub(SafeUint.Uint256(args.startTime)).val();
        if (duration > _ONE_YEAR) {
            return #Err("Incentive duration cannot be more than 1 year");
        };

        // check reward token
        let stakingTokenAdapter = TokenFactory.getAdapter(
            args.stakingToken.address,
            args.stakingToken.standard,
        );
        let rewardTokenAdapter = TokenFactory.getAdapter(
            args.rewardToken.address,
            args.rewardToken.standard,
        );
        try {
            let _stakingTokenMetadata = await stakingTokenAdapter.metadata();
        } catch (e) {
            return #Err("Illegal staking token: " # debug_show (Error.message(e)));
        };
        try {
            let _rewardTokenMetadata = await rewardTokenAdapter.metadata();
        } catch (e) {
            return #Err("Illegal reward token: " # debug_show (Error.message(e)));
        };

        // check cycle balance
        switch (await _stakingPoolFactoryAct.getCycleInfo()) {
            case (#ok(cycleInfo)) {
                if (cycleInfo.balance < 4 * _initCycles) {
                    return #Err("Insufficient Cycle Balance.");
                };
            };
            case (#err(code)) {
                return #Err("Get cycle info of StakingPoolFactory failed: " # debug_show (code));
            };
        };

        return #Ok(debug_show (args));
    };

    public shared (msg) func setAdminsValidate(admins : [Principal]) : async Result {
        assert (Principal.equal(msg.caller, governanceCid));
        return #Ok(debug_show (admins));
    };

    public shared ({ caller }) func setStakingPoolAdminsValidate(stakingPoolCid : Principal, admins : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkStakingPool(stakingPoolCid))) {
            return #Err(Principal.toText(stakingPoolCid) # " doesn't exist.");
        };
        return #Ok(debug_show (stakingPoolCid) # ", " # debug_show (admins));
    };

    public shared ({ caller }) func addStakingPoolControllersValidate(stakingPoolCid : Principal, controllers : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkStakingPool(stakingPoolCid))) {
            return #Err(Principal.toText(stakingPoolCid) # " doesn't exist.");
        };
        return #Ok(debug_show (stakingPoolCid) # ", " # debug_show (controllers));
    };

    public shared ({ caller }) func removeStakingPoolControllersValidate(stakingPoolCid : Principal, controllers : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkStakingPool(stakingPoolCid))) {
            return #Err(Principal.toText(stakingPoolCid) # " doesn't exist.");
        };
        for (it in controllers.vals()) {
            if (Principal.equal(it, stakingPoolFactoryCid)) {
                return #Err("StakingPoolFactory must be the controller of StakingPool.");
            };
        };
        return #Ok(debug_show (stakingPoolCid) # ", " # debug_show (controllers));
    };

    public query func getInitArgs() : async Result.Result<{ stakingPoolFactoryCid : Principal; governanceCid : Principal }, Types.Error> {
        #ok({
            stakingPoolFactoryCid = stakingPoolFactoryCid;
            governanceCid = governanceCid;
        });
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "1.0.0";
    public query func getVersion() : async Text { _version };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _checkStakingPool(stakingPoolCid : Principal) : async Bool {
        switch (await _stakingPoolFactoryAct.getStakingPool(stakingPoolCid)) {
            case (#ok(stakingPool)) {
                return true;
            };
            case (#err(msg)) {
                return false;
            };
        };
    };
};
