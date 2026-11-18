#import "RelayFrame.h"

typedef void (^SocksProxyLog)(NSString *event, NSDictionary *fields);
typedef NSTimeInterval (^SocksProxyClock)(void);

// Calls and handlers run on the link's run loop.
@interface SocksProxy : NSObject
@property (readonly) uint16_t boundPort;
@property (readonly) NSUInteger streamLimit;
- (instancetype)initWithSend:(RelayFrameHandler)send log:(SocksProxyLog)log;
- (instancetype)initWithSend:(RelayFrameHandler)send log:(SocksProxyLog)log
                    wideMode:(BOOL)wideMode clock:(SocksProxyClock)clock;
- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error;
- (void)stop;
- (void)tick;
- (BOOL)receive:(RelayMessage)type streamID:(uint32_t)streamID payload:(NSData *)payload;
@end
