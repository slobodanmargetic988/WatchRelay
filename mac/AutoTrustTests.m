#import "AutoTrust.h"

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSData *Sequence(uint8_t start) {
    uint8_t bytes[32];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) {
        bytes[index] = start + (uint8_t)index;
    }
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSString *Hex(NSData *bytes) {
    NSMutableString *output = [NSMutableString string];
    const uint8_t *input = bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        [output appendFormat:@"%02x", input[index]];
    }
    return output;
}

int main(void) {
    @autoreleasepool {
        NSData *key = Sequence(0);
        NSData *mac = Sequence(32);
        NSData *watch = Sequence(64);
        NSData *watchProof = AutoTrustProof(key, AutoWatchProofContext, mac, watch);
        NSData *macProof = AutoTrustProof(key, AutoMacProofContext, mac, watch);
        Require([Hex(watchProof) isEqualToString:@"402e5137dbb2612f5f38cea9f914fa95d9dda519aac19a7ac8229e70d395fb87"],
            "watch proof matches independent HMAC-SHA256 vector");
        Require([Hex(macProof) isEqualToString:@"d5ea85976ed0329f9d25ad11ff7c5499284d9e83b31e255e3fd5a44193125708"],
            "Mac proof matches independent HMAC-SHA256 vector");
        Require(!AutoTrustMatches(watchProof, macProof), "proofs cannot be reflected across roles");
        Require(!AutoTrustMatches(watchProof, AutoTrustProof(key, AutoWatchProofContext, watch, mac)), "nonce order is authenticated");
        Require(!AutoTrustMatches(watchProof, AutoTrustProof(Sequence(1), AutoWatchProofContext, mac, watch)), "different key is rejected");
        Require(!AutoTrustMatches(watchProof, [macProof subdataWithRange:NSMakeRange(0, 31)]), "truncated proof is rejected");
        Require(AutoTrustMatches(watchProof, watchProof), "matching proofs are accepted");
        puts("PASS: automatic connection HMAC vectors, role separation and nonce binding");
    }
    return 0;
}
