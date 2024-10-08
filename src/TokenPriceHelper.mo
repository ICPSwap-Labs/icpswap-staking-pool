import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Float "mo:base/Float";
module {
    public class TokenPrice(canister_id : ?Text) {
        let default_canister_id : Text = "g54jq-hiaaa-aaaag-qck5q-cai";
        let price_canister_id : Text = switch (canister_id) {
            case (?_canister_id) { _canister_id };
            case (null) { default_canister_id };
        };

        let tokenPrice : ITokenPrice = actor (price_canister_id) : ITokenPrice;

        var tokenPriceMap = HashMap.HashMap<Text, TokenPriceInfo>(1, Text.equal, Text.hash);

        public func syncToken2ICPPrice() : async () {
            let tokenPriceArray = await tokenPrice.getTokenPriceMetadata();
            tokenPriceMap := HashMap.fromIter(
                tokenPriceArray.vals(),
                1,
                Text.equal,
                Text.hash,
            );
        };

        public func getToken2ICPPrice(address : Text) : Float {
            switch (tokenPriceMap.get(address)) {
                case (?price) {
                    price.priceICP;
                };
                case (_) {
                    0.0000;
                };
            };
        };

        public func getToken2USDPrice(address : Text) : Float {
            switch (tokenPriceMap.get(address)) {
                case (?price) {
                    if(price.priceUSD == 0.0){
                        return price.priceICP * getToken2USDPrice("ryjl3-tyaaa-aaaaa-aaaba-cai");
                    };
                    price.priceUSD;
                };
                case (_) {
                    0.0000;
                };
            };
        };
    };

    public type TokenPriceInfo = {
        tokenId : Text;
        volumeUSD7d : Float;
        priceICP : Float;
        priceUSD : Float;
    };

    public type ITokenPrice = actor {
        getTokenPrice : query () -> async [(Text, TokenPriceInfo)];
        getTokenPriceMetadata : query () -> async [(Text, TokenPriceInfo)];
    };
};
