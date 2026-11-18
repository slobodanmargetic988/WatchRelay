#import "RelayFrame.h"

NSString *const RelayServiceUUID = @"0c5bc6fa-c662-4fc0-bc94-62a1ce97de9d";
const NSUInteger RelayHeaderLength = 12;

static BOOL ValidFrame(RelayMessage type, uint32_t streamID, NSUInteger length) {
    BOOL streamFrame = type >= RelayOpen && type <= RelayWindowUpdate;
    if (streamFrame == (streamID == 0)) {
        return NO;
    }
    switch (type) {
        case RelayHello:
        case RelayHelloAck:
        case RelayCellProbe:
        case RelayAutoEnrolled:
            return length == 0;
        case RelayPing:
        case RelayPong:
            return length >= 1 && length <= 256;
        case RelayCellResult:
            return length >= 1 && length <= 1024;
        case RelayOpen:
            return length >= 5 && length <= 259;
        case RelayOpenOK:
            return length == 7 || length == 19;
        case RelayOpenError:
        case RelayClose:
            return length == 1;
        case RelayData:
            return length >= 1 && length <= 16384;
        case RelayHalfClose:
            return length == 0;
        case RelayWindowUpdate:
            return length == 4;
        case RelayAutoEnroll:
        case RelayAutoChallenge:
        case RelayAutoAccept:
            return length == 32;
        case RelayAutoProof:
            return length == 64;
    }
    return NO;
}

NSData *RelayEncode(RelayMessage type, NSData *payload) {
    return RelayEncodeStream(type, 0, payload);
}

NSData *RelayEncodeStream(RelayMessage type, uint32_t streamID, NSData *payload) {
    NSUInteger length = payload.length;
    if (!ValidFrame(type, streamID, length)) {
        return nil;
    }
    uint8_t header[12] = {1, type, 0, 0,
        (uint8_t)(streamID >> 24), (uint8_t)(streamID >> 16), (uint8_t)(streamID >> 8), (uint8_t)streamID,
        (uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
    NSMutableData *encoded = [NSMutableData dataWithBytes:header length:sizeof(header)];
    if (length) {
        [encoded appendData:payload];
    }
    return encoded;
}

@implementation RelayFrameDecoder {
    uint8_t _header[12];
    NSUInteger _headerLength;
    NSUInteger _expectedLength;
    uint32_t _streamID;
    NSMutableData *_payload;
    BOOL _failed;
}

- (BOOL)appendBytes:(const void *)bytes length:(NSUInteger)length handler:(RelayFrameHandler)handler {
    const uint8_t *next = bytes;
    while (length > 0 && !_failed) {
        if (_headerLength < RelayHeaderLength) {
            NSUInteger count = MIN(RelayHeaderLength - _headerLength, length);
            memcpy(_header + _headerLength, next, count);
            _headerLength += count;
            next += count;
            length -= count;
            if (_headerLength < RelayHeaderLength) {
                break;
            }

            _expectedLength = ((uint32_t)_header[8] << 24) | ((uint32_t)_header[9] << 16)
                | ((uint32_t)_header[10] << 8) | _header[11];
            _streamID = ((uint32_t)_header[4] << 24) | ((uint32_t)_header[5] << 16)
                | ((uint32_t)_header[6] << 8) | _header[7];
            if (_header[0] != 1 || _header[2] || _header[3] || !ValidFrame(_header[1], _streamID, _expectedLength)) {
                _failed = YES;
                break;
            }
            _payload = [NSMutableData dataWithCapacity:_expectedLength];
        }

        NSUInteger count = MIN(_expectedLength - _payload.length, length);
        [_payload appendBytes:next length:count];
        next += count;
        length -= count;
        if (_payload.length == _expectedLength) {
            RelayMessage type = _header[1];
            NSData *payload = _payload;
            _payload = nil;
            _headerLength = 0;
            handler(type, _streamID, payload);
        }
    }
    return !_failed;
}
@end
