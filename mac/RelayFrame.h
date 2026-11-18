#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, RelayMessage) {
    RelayHello = 1,
    RelayHelloAck,
    RelayPing,
    RelayPong,
    RelayCellProbe,
    RelayCellResult,
    RelayOpen,
    RelayOpenOK,
    RelayOpenError,
    RelayData,
    RelayHalfClose,
    RelayClose,
    RelayWindowUpdate,
    RelayAutoEnroll,
    RelayAutoEnrolled,
    RelayAutoChallenge,
    RelayAutoProof,
    RelayAutoAccept,
};

extern NSString *const RelayServiceUUID;
extern const NSUInteger RelayHeaderLength;

typedef void (^RelayFrameHandler)(RelayMessage type, uint32_t streamID, NSData *payload);

NSData *RelayEncode(RelayMessage type, NSData *payload);
NSData *RelayEncodeStream(RelayMessage type, uint32_t streamID, NSData *payload);

@interface RelayFrameDecoder : NSObject
// A malformed frame poisons the decoder. Close the link after a false return.
- (BOOL)appendBytes:(const void *)bytes length:(NSUInteger)length handler:(RelayFrameHandler)handler;
@end
