#import "RelayFrame.h"

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        const uint8_t pattern[] = {0x00, 0xff, 0x10, 0x00, 0x03};
        NSData *echo = [NSData dataWithBytes:pattern length:sizeof(pattern)];
        NSData *ack = RelayEncode(RelayHelloAck, NSData.data);
        NSData *pong = RelayEncode(RelayPong, echo);
        const uint8_t wirePong[] = {
            0x01, 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05,
            0x00, 0xff, 0x10, 0x00, 0x03,
        };
        Require([pong isEqualToData:[NSData dataWithBytes:wirePong length:sizeof(wirePong)]],
            "PONG matches the cross-platform wire format");
        NSMutableData *combined = [ack mutableCopy];
        [combined appendData:pong];
        for (NSUInteger split = 0; split <= combined.length; split++) {
            RelayFrameDecoder *decoder = [RelayFrameDecoder new];
            __block NSUInteger seen = 0;
            RelayFrameHandler check = ^(RelayMessage type, uint32_t streamID, NSData *payload) {
                Require(streamID == 0, "control stream ID");
                if (seen == 0) {
                    Require(type == RelayHelloAck && payload.length == 0, "empty ACK frame");
                } else {
                    Require(type == RelayPong && [payload isEqualToData:echo], "binary PONG frame");
                }
                seen++;
            };
            const uint8_t *bytes = combined.bytes;
            Require([decoder appendBytes:bytes length:split handler:check], "first fragment");
            Require([decoder appendBytes:bytes + split length:combined.length - split handler:check], "remaining fragment");
            Require(seen == 2, "coalesced frames were decoded in order");
        }

        RelayFrameDecoder *decoder = [RelayFrameDecoder new];
        const uint8_t *bytes = combined.bytes;
        __block NSUInteger seen = 0;
        for (NSUInteger index = 0; index < combined.length; index++) {
            Require([decoder appendBytes:bytes + index length:1 handler:^(RelayMessage type, uint32_t streamID, NSData *payload) {
                (void)type;
                (void)streamID;
                (void)payload;
                seen++;
            }], "single-byte fragmentation");
        }
        Require(seen == 2, "byte-by-byte decode produced two frames");

        const uint8_t malformed[][12] = {
            {2, RelayHelloAck, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            {1, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            {1, RelayHelloAck, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0},
            {1, RelayHelloAck, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0},
            {1, RelayHelloAck, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
            {1, RelayPong, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
            {1, RelayPong, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1},
            {1, RelayCellResult, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff},
        };
        RelayFrameHandler unexpected = ^(RelayMessage type, uint32_t streamID, NSData *payload) {
            (void)type;
                (void)streamID;
            (void)payload;
            Require(NO, "malformed data must not emit a frame");
        };
        for (NSUInteger index = 0; index < sizeof(malformed) / sizeof(*malformed); index++) {
            decoder = [RelayFrameDecoder new];
            Require(![decoder appendBytes:malformed[index] length:sizeof(*malformed) handler:unexpected],
                "reject malformed header immediately");
            Require(![decoder appendBytes:ack.bytes length:ack.length handler:unexpected],
                "decoder stays closed after a malformed header");
        }
        Require(RelayEncode(RelayHello, echo) == nil, "encoder rejects invalid control payload");
        Require(RelayEncode(RelayPong, NSData.data) == nil, "encoder rejects empty PONG");
        puts("PASS: WatchRelay frame codec fragmentation, coalescing, binary payloads, and malformed headers");
    }
    return 0;
}
