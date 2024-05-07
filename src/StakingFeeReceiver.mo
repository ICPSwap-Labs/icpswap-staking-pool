import Prim "mo:⛔";
import Nat "mo:base/Nat";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Bool "mo:base/Bool";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";
import TokenAdapterTypes "mo:token-adapter/Types";
import TokenFactory "mo:token-adapter/TokenFactory";
import Types "./Types";
shared (initMsg) actor class StakingFeeReceiver() = this {

    private func _checkStandard(standard : Text) : Bool {
        if (
            Text.notEqual(standard, "DIP20") 
            and Text.notEqual(standard, "DIP20-WICP") 
            and Text.notEqual(standard, "DIP20-XTC") 
            and Text.notEqual(standard, "EXT") 
            and Text.notEqual(standard, "ICRC1") 
            and Text.notEqual(standard, "ICRC2") 
            and Text.notEqual(standard, "ICRC3") 
            and Text.notEqual(standard, "ICP")
        ) {
            return false;
        };
        return true;
    };

    public shared ({ caller }) func claim(stakingPool : Principal) : async Result.Result<Text, Types.Error> {
        _checkPermission(caller);
        var stakingPoolAct = actor (Principal.toText(stakingPool)) : Types.IStakingPool;
        switch (await stakingPoolAct.withdrawRewardFee()) {
            case (#ok(msg)) { return #ok(msg) };
            case (#err(msg)) { return #err(#InternalError(debug_show (msg))); };
        };
    };

    public shared ({ caller }) func transfer(token : Types.Token, recipient : Principal, value : Nat) : async Result.Result<Nat, Types.Error> {
        _checkPermission(caller);
        if (not _checkStandard(token.standard)) { return #err(#UnsupportedToken("Wrong token standard.")); };
        var tokenAct : TokenAdapterTypes.TokenAdapter = TokenFactory.getAdapter(token.address, token.standard);
        var fee : Nat = await tokenAct.fee();
        if (value > fee) {
            var amount : Nat = Nat.sub(value, fee);
            switch (await tokenAct.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = recipient; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) { return #ok(amount) };
                case (#Err(msg)) { return #err(#InternalError(debug_show (msg))); };
            };
            return #ok(amount);
        } else {
            return #ok(0);
        };
    };

    public shared ({ caller }) func transferAll(token : Types.Token, recipient : Principal) : async Result.Result<Nat, Types.Error> {
        _checkPermission(caller);
        if (not _checkStandard(token.standard)) { return #err(#UnsupportedToken("Wrong token standard.")); };
        var tokenAct : TokenAdapterTypes.TokenAdapter = TokenFactory.getAdapter(token.address, token.standard);
        var value : Nat = await tokenAct.balanceOf({ owner = Principal.fromActor(this); subaccount = null; });
        var fee : Nat = await tokenAct.fee();
        if (value > fee) {
            var amount : Nat = Nat.sub(value, fee);
            switch (await tokenAct.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = recipient; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
                case (#Ok(index)) { return #ok(amount) };
                case (#Err(msg)) { return #err(#InternalError(debug_show (msg))); };
            };
            return #ok(amount);
        } else {
            return #ok(0);
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    private func _checkPermission(caller: Principal) {
        assert(Prim.isController(caller));
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "3.0.0";
    public query func getVersion() : async Text { _version };

    system func preupgrade() {};

    system func postupgrade() {};

    system func inspect({
        arg : Blob;
        caller : Principal;
        msg : Types.StakingFeeReceiver;
    }) : Bool {
        return switch (msg) {
            // Controller
            case (#claim args) { Prim.isController(caller) };
            case (#transfer args) { Prim.isController(caller) };
            // Anyone
            case (_) { true };
        };
    };
};