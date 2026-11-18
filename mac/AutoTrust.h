#import <Foundation/Foundation.h>

extern NSString *const AutoWatchProofContext;
extern NSString *const AutoMacProofContext;

NSData *AutoTrustRandom(void);
NSData *AutoTrustProof(NSData *key, NSString *context, NSData *macNonce, NSData *watchNonce);
BOOL AutoTrustMatches(NSData *first, NSData *second);
NSData *AutoTrustReadKey(NSString *address, NSError **error);
BOOL AutoTrustWriteKey(NSString *address, NSData *key, NSError **error);
