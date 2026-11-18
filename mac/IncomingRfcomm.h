#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IncomingRfcommOpened)(IOBluetoothRFCOMMChannel *channel);

/// Keep one listener alive across Bluetooth connection losses. Call on the main thread.
@interface IncomingRfcomm : NSObject

@property (nonatomic, readonly) BluetoothRFCOMMChannelID channelID;

- (instancetype)initWithDevice:(IOBluetoothDevice *)device
                   serviceUUID:(NSString *)serviceUUID
                        opened:(IncomingRfcommOpened)opened;

/// With application authentication enabled, opened receives a candidate channel.
/// The caller must verify both peers before sending HELLO or starting the relay.
- (instancetype)initWithDevice:(IOBluetoothDevice *)device
                   serviceUUID:(NSString *)serviceUUID
allowApplicationAuthentication:(BOOL)allowApplicationAuthentication
                        opened:(IncomingRfcommOpened)opened;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
