#import "IncomingRfcomm.h"

static NSString *const IncomingErrorDomain = @"com.weeyuga.watchrelay.mac.incoming";
static NSString *const PreviousChannel = @"previous_incoming_channel";
static const NSTimeInterval VerificationTimeout = 2;
static const NSTimeInterval VerificationInterval = 0.1;

static NSString *CanonicalAddress(IOBluetoothDevice *device) {
    return [[device.addressString stringByReplacingOccurrencesOfString:@":" withString:@"-"] lowercaseString];
}

static BOOL Fail(NSError **error, NSInteger code, NSString *detail) {
    if (error) {
        *error = [NSError errorWithDomain:IncomingErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: detail}];
    }
    return NO;
}

@implementation IncomingRfcomm {
    IOBluetoothDevice *_device;
    NSString *_expectedAddress;
    NSString *_serviceUUID;
    BOOL _allowApplicationAuthentication;
    IncomingRfcommOpened _opened;
    IOBluetoothSDPServiceRecord *_record;
    IOBluetoothUserNotification *_notification;
    NSMutableSet<NSString *> *_reportedRejections;
    IOBluetoothRFCOMMChannel *_pendingChannel;
    IOBluetoothDevice *_pendingPeer;
    NSTimer *_verificationTimer;
    NSTimeInterval _verificationDeadline;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)device
                   serviceUUID:(NSString *)serviceUUID
                        opened:(IncomingRfcommOpened)opened {
    return [self initWithDevice:device serviceUUID:serviceUUID allowApplicationAuthentication:NO opened:opened];
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)device
                   serviceUUID:(NSString *)serviceUUID
allowApplicationAuthentication:(BOOL)allowApplicationAuthentication
                        opened:(IncomingRfcommOpened)opened {
    self = [super init];
    if (self) {
        _device = device;
        _expectedAddress = CanonicalAddress(device);
        _serviceUUID = [serviceUUID copy];
        _allowApplicationAuthentication = allowApplicationAuthentication;
        _opened = [opened copy];
        _reportedRejections = [NSMutableSet set];
    }
    return self;
}

- (BOOL)startWithError:(NSError **)error {
    if (_notification) {
        return YES;
    }
    if (!_expectedAddress.length || !_device.isPaired) {
        return Fail(error, 1, @"Pair the watch before starting the incoming Bluetooth service.");
    }
    NSUUID *service = [[NSUUID alloc] initWithUUIDString:_serviceUUID];
    if (!service) {
        return Fail(error, 2, @"The incoming Bluetooth service UUID is invalid.");
    }
    uuid_t uuidBytes;
    [service getUUIDBytes:uuidBytes];
    IOBluetoothSDPUUID *uuid = [IOBluetoothSDPUUID uuidWithBytes:uuidBytes length:sizeof(uuidBytes)];
    IOBluetoothSDPUUID *l2cap = [IOBluetoothSDPUUID uuid16:0x0100];
    IOBluetoothSDPUUID *rfcomm = [IOBluetoothSDPUUID uuid16:0x0003];
    // macOS can leave the previous listener's channel reserved until Bluetooth restarts.
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.weeyuga.watchrelay.mac.bluetooth"];
    NSInteger previous = [preferences integerForKey:PreviousChannel];
    NSInteger requested = previous >= 16 && previous <= 30 ? 16 + (previous - 15) % 15 : 24;
    NSString *override = NSProcessInfo.processInfo.environment[@"WATCHRELAY_LOCAL_RFCOMM_CHANNEL"];
    if (override) {
        NSScanner *scanner = [NSScanner scannerWithString:override];
        if (![scanner scanInteger:&requested] || !scanner.isAtEnd || requested < 1 || requested > 30) {
            return Fail(error, 6, @"The diagnostic local Bluetooth channel must be from 1 to 30.");
        }
    }
    // Always use the actual assignment returned by the SDP API.
    NSDictionary *requestedChannel = @{@"DataElementType": @1, @"DataElementSize": @1,
                                       @"DataElementValue": @(requested)};
    NSDictionary *serviceDictionary = @{
        @"0001": @[uuid],
        @"0004": @[@[l2cap], @[rfcomm, requestedChannel]],
        @"0100": @"WatchRelay",
    };
    _record = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:serviceDictionary];
    if (!_record) {
        return Fail(error, 3, @"macOS did not publish the incoming WatchRelay Bluetooth service.");
    }
    BluetoothRFCOMMChannelID channel = 0;
    IOReturn status = [_record getRFCOMMChannelID:&channel];
    if (status != kIOReturnSuccess || channel == 0 || channel > 30) {
        [self stop];
        return Fail(error, 4, @"macOS did not assign a usable RFCOMM service channel.");
    }
    _channelID = channel;
    _notification = [IOBluetoothRFCOMMChannel registerForChannelOpenNotifications:self
        selector:@selector(channelOpened:channel:) withChannelID:channel
        direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    if (!_notification) {
        [self stop];
        return Fail(error, 5, @"macOS did not register the incoming RFCOMM listener.");
    }
    [preferences setInteger:channel forKey:PreviousChannel];
    return YES;
}

- (void)channelOpened:(IOBluetoothUserNotification *)notification
              channel:(IOBluetoothRFCOMMChannel *)channel {
    if (!NSThread.isMainThread) {
        CFRunLoopRef loop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{
            [self channelOpened:notification channel:channel];
        });
        CFRunLoopWakeUp(loop);
        return;
    }
    if (!_notification || notification != _notification) {
        [self reject:channel reason:@"inactive_notification"];
        return;
    }
    if (!channel.isIncoming || [channel getChannelID] != _channelID) {
        [self reject:channel reason:@"unexpected_channel"];
        return;
    }
    if (!channel.isOpen) {
        [self reject:channel reason:@"channel_not_open"];
        return;
    }
    IOBluetoothDevice *peer = [channel getDevice];
    if (!peer.isPaired) {
        [self reject:channel reason:@"peer_not_bonded"];
        return;
    }
    if (![CanonicalAddress(peer) isEqualToString:_expectedAddress]) {
        [self reject:channel reason:@"peer_address_mismatch"];
        return;
    }
    if (_allowApplicationAuthentication) {
        // The caller authenticates this candidate before using the relay protocol.
        _opened(channel);
        return;
    }
    if (_pendingChannel) {
        [self reject:channel reason:@"verification_busy"];
        return;
    }

    _pendingChannel = channel;
    _pendingPeer = peer;
    _verificationDeadline = NSProcessInfo.processInfo.systemUptime + VerificationTimeout;
    [self verifyPending];
    if (_pendingChannel) {
        __weak IncomingRfcomm *weakSelf = self;
        _verificationTimer = [NSTimer scheduledTimerWithTimeInterval:VerificationInterval repeats:YES
            block:^(NSTimer *timer) {
                (void)timer;
                [weakSelf verifyPending];
            }];
    }
}

- (void)verifyPending {
    IOBluetoothRFCOMMChannel *channel = _pendingChannel;
    IOBluetoothDevice *peer = _pendingPeer;
    if (!channel.isOpen || !peer.isPaired || !_device.isPaired) {
        [self clearVerification];
        [self reject:channel reason:@"channel_closed_during_verification"];
        return;
    }

    // The channel notification can precede macOS's baseband state update.
    // Query both the incoming peer object and our canonical paired device.
    BOOL peerConnected = peer.isConnected;
    BOOL knownConnected = _device.isConnected;
    if ((peerConnected && [peer getEncryptionMode] != kEncryptionDisabled) ||
        (knownConnected && [_device getEncryptionMode] != kEncryptionDisabled)) {
        [self clearVerification];
        _opened(channel);
        return;
    }

    // The watch opens an authenticated, encrypted RFCOMM socket. Fail closed if
    // macOS cannot verify link encryption for the expected Classic bond.
    if (NSProcessInfo.processInfo.systemUptime >= _verificationDeadline) {
        [self clearVerification];
        [self reject:channel reason:(peerConnected || knownConnected) ? @"encryption_unverified" : @"baseband_not_connected"];
    }
}

- (void)clearVerification {
    [_verificationTimer invalidate];
    _verificationTimer = nil;
    _pendingChannel = nil;
    _pendingPeer = nil;
}

- (void)reject:(IOBluetoothRFCOMMChannel *)channel reason:(NSString *)reason {
    if (![_reportedRejections containsObject:reason]) {
        [_reportedRejections addObject:reason];
        NSLog(@"WatchRelay incoming Bluetooth rejected (%@).", reason);
    }
    [channel closeChannel];
}

- (void)stop {
    [_pendingChannel closeChannel];
    [self clearVerification];
    [_notification unregister];
    _notification = nil;
    [_record removeServiceRecord];
    _record = nil;
    _channelID = 0;
}

- (void)dealloc {
    [self stop];
}

@end
