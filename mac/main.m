#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <poll.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>

#import "RelayFrame.h"
#import "SocksProxy.h"
#import "IncomingRfcomm.h"
#import "AutoTrust.h"

static const NSTimeInterval ConnectTimeout = 25;
static const NSTimeInterval ApprovalTimeout = 65;
static const NSTimeInterval ProbeTimeout = 45;
static const NSTimeInterval PingTimeout = 5;
static const NSUInteger PingGoal = 8;
static const NSTimeInterval RelayPingInterval = 10;
static const NSTimeInterval RelayIdleTimeout = 25;
static const NSTimeInterval AutoAuthenticationTimeout = 8;
static const NSUInteger MaxQueuedBytes = 2 * 1024 * 1024;
static const NSUInteger MaxQueuedFrames = 1024;
static volatile sig_atomic_t interrupted = 0;

static void Interrupt(int signalNumber) {
    (void)signalNumber;
    interrupted = 1;
}

static NSTimeInterval Uptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static void Print(NSString *message) {
    puts(message.UTF8String);
}

static void PrintError(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
}

static NSString *Printable(NSString *value) {
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}

static NSString *StatusMessage(NSString *message, IOReturn status) {
    return [NSString stringWithFormat:@"%@ (0x%08x).", message, (uint32_t)status];
}

static NSURL *DiagnosticsFolder(void) {
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
        inDomains:NSUserDomainMask].firstObject;
    return [library URLByAppendingPathComponent:@"Logs/WatchRelay" isDirectory:YES];
}

@interface ProbeLog : NSObject
@property (readonly) NSURL *url;
- (instancetype)initWithError:(NSError **)error;
- (void)event:(NSString *)event fields:(NSDictionary *)fields;
@end

@implementation ProbeLog {
    NSFileHandle *_file;
    NSString *_session;
    NSISO8601DateFormatter *_timestamp;
    NSUInteger _entries;
    BOOL _writeFailed;
}

- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _session = NSUUID.UUID.UUIDString;
    _timestamp = [NSISO8601DateFormatter new];
    _timestamp.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *folder = DiagnosticsFolder();
    NSDictionary *directoryMode = @{NSFilePosixPermissions: @0700};
    if (![manager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:directoryMode error:error]) {
        return nil;
    }
    NSString *filename = [NSString stringWithFormat:@"probe-%lld-%@.jsonl",
        (long long)(NSDate.date.timeIntervalSince1970 * 1000), _session];
    _url = [folder URLByAppendingPathComponent:filename];
    int fd = open(_url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }
    _file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSArray<NSString *> *files = [manager contentsOfDirectoryAtPath:folder.path error:nil];
    NSPredicate *reports = [NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@ AND SELF ENDSWITH %@", @"probe-", @".jsonl"];
    NSArray<NSString *> *sorted = [[files filteredArrayUsingPredicate:reports] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger index = 0; index + 16 < sorted.count; index++) {
        [manager removeItemAtURL:[folder URLByAppendingPathComponent:sorted[index]] error:nil];
    }
    return self;
}

- (void)event:(NSString *)event fields:(NSDictionary *)fields {
    if (_entries >= 2048 || _writeFailed) {
        return;
    }
    _entries++;
    NSMutableDictionary *record = [fields mutableCopy];
    record[@"event"] = event;
    record[@"build"] = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"dev";
    record[@"session"] = _session;
    record[@"time"] = [_timestamp stringFromDate:NSDate.date];
    record[@"monotonic_ms"] = @((uint64_t)(Uptime() * 1000));
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    if (!line || ![_file writeData:line error:nil]) {
        _writeFailed = YES;
        PrintError(@"Could not continue writing the desktop diagnostics file.");
    }
}
@end

static NSArray<IOBluetoothDevice *> *PairedDevices(void) {
    NSArray<IOBluetoothDevice *> *devices = [IOBluetoothDevice pairedDevices];
    return [devices sortedArrayUsingComparator:^NSComparisonResult(IOBluetoothDevice *a, IOBluetoothDevice *b) {
        return [a.addressString compare:b.addressString];
    }] ?: @[];
}

static BOOL BluetoothReady(void) {
    IOBluetoothHostController *controller = [IOBluetoothHostController defaultController];
    if (!controller || controller.powerState == kBluetoothHCIPowerStateUnintialized) {
        PrintError(@"The Mac's Bluetooth adapter is unavailable. Check Bluetooth and Privacy & Security in System Settings.");
        return NO;
    }
    if (controller.powerState != kBluetoothHCIPowerStateON) {
        PrintError(@"Bluetooth is off. Turn it on in System Settings and retry.");
        return NO;
    }
    return YES;
}

static NSString *NormalizeAddress(NSString *input) {
    if (!input.length) {
        return nil;
    }
    NSString *address = [input stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    NSString *pattern = @"^[A-Fa-f0-9]{2}(-[A-Fa-f0-9]{2}){5}$";
    return [address rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound ? nil : address;
}

static IOBluetoothDevice *SelectDevice(NSString *selection) {
    if (!selection.length) {
        return nil;
    }
    NSString *address = NormalizeAddress(selection);
    if (address) {
        for (IOBluetoothDevice *device in PairedDevices()) {
            NSString *pairedAddress = NormalizeAddress(device.addressString);
            if (pairedAddress && [pairedAddress caseInsensitiveCompare:address] == NSOrderedSame) {
                return device;
            }
        }
        return [IOBluetoothDevice deviceWithAddressString:address];
    }
    NSScanner *scanner = [NSScanner scannerWithString:selection];
    scanner.charactersToBeSkipped = nil;
    NSInteger index = 0;
    NSArray<IOBluetoothDevice *> *paired = PairedDevices();
    if ([scanner scanInteger:&index] && scanner.isAtEnd && index >= 1 && (NSUInteger)index <= paired.count) {
        return paired[(NSUInteger)index - 1];
    }
    return nil;
}

static void PrintDevices(NSArray<IOBluetoothDevice *> *devices) {
    if (!devices.count) {
        Print(@"No Classic Bluetooth devices found.");
    }
    for (NSUInteger index = 0; index < devices.count; index++) {
        IOBluetoothDevice *device = devices[index];
        Print([NSString stringWithFormat:@"%lu. %@ [%@]%@", index + 1,
            Printable(device.name) ?: @"Unnamed device", device.addressString ?: @"address unavailable",
            device.isPaired ? @" paired" : @""]);
    }
}

static void RunLoopTick(void) {
    if (![NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]) {
        [NSThread sleepForTimeInterval:0.05];
    }
}

static BOOL DeferToMainRunLoop(void (^callback)(void)) {
    if (NSThread.isMainThread) {
        return NO;
    }
    CFRunLoopRef runLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(runLoop, kCFRunLoopDefaultMode, ^{
        @autoreleasepool { callback(); }
    });
    CFRunLoopWakeUp(runLoop);
    return YES;
}

@interface DeviceScan : NSObject <IOBluetoothDeviceInquiryDelegate>
@property BOOL done;
@property IOReturn result;
@end

@implementation DeviceScan
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    (void)sender;
    (void)aborted;
    self.result = error;
    self.done = YES;
}
@end

static int Scan(void) {
    DeviceScan *delegate = [DeviceScan new];
    IOBluetoothDeviceInquiry *inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:delegate];
    inquiry.inquiryLength = 10;
    inquiry.updateNewDeviceNames = NO;
    IOReturn status = [inquiry start];
    if (status != kIOReturnSuccess) {
        PrintError(StatusMessage(@"Could not start Classic Bluetooth discovery", status));
        return 1;
    }
    Print(@"Looking for discoverable Classic Bluetooth devices for up to 24 seconds.");
    NSTimeInterval deadline = Uptime() + 24;
    while (!delegate.done && !interrupted && Uptime() < deadline) {
        @autoreleasepool { RunLoopTick(); }
    }
    // Recent macOS versions can keep restarting the radio inquiry until stopped.
    if (!delegate.done) {
        status = [inquiry stop];
    }
    if (interrupted) {
        PrintError(@"Discovery cancelled.");
        return 1;
    }
    if (status != kIOReturnSuccess || delegate.result != kIOReturnSuccess) {
        PrintError(StatusMessage(@"Bluetooth discovery failed", status ?: delegate.result));
        return 1;
    }
    PrintDevices([inquiry foundDevices]);
    return 0;
}

@interface DevicePairing : NSObject <IOBluetoothDevicePairDelegate>
- (int)run:(IOBluetoothDevice *)device;
@end

@implementation DevicePairing {
    BOOL _waitingForConfirmation;
    BOOL _done;
    IOReturn _status;
}

- (int)run:(IOBluetoothDevice *)device {
    if (!device) {
        PrintError(@"The selected Bluetooth address is unavailable.");
        return 1;
    }
    if (device.isPaired) {
        Print(@"The selected device is already paired with this Mac.");
        return 0;
    }
    if (!isatty(STDIN_FILENO)) {
        PrintError(@"Run pairing in Terminal so you can compare the codes.");
        return 1;
    }
    IOBluetoothDevicePair *pair = [IOBluetoothDevicePair pairWithDevice:device];
    if (!pair) {
        PrintError(@"Could not create a Bluetooth pairing request.");
        return 1;
    }
    pair.delegate = self;
    NSTimeInterval deadline = Uptime() + 60;
    Print(@"Requesting Bluetooth pairing. Keep the watch discoverable and look for a code on its screen.");
    IOReturn status = [pair start];
    if (status != kIOReturnSuccess) {
        PrintError(StatusMessage(@"Could not start pairing", status));
        return 1;
    }
    while (!_done && !interrupted && Uptime() < deadline) {
        @autoreleasepool {
            RunLoopTick();
            if (_waitingForConfirmation && !_done) {
                struct pollfd input = {STDIN_FILENO, POLLIN, 0};
                if (poll(&input, 1, 0) == 1) {
                    char answer[16] = "";
                    char *read = fgets(answer, sizeof(answer), stdin);
                    BOOL confirm = read && (!strcasecmp(answer, "y\n") || !strcasecmp(answer, "yes\n"));
                    _waitingForConfirmation = NO;
                    [pair replyUserConfirmation:confirm];
                    if (!confirm) {
                        [pair stop];
                        PrintError(@"Pairing was declined.");
                        return 1;
                    }
                }
            }
        }
    }
    if (!_done) {
        if (_waitingForConfirmation) {
            [pair replyUserConfirmation:NO];
        }
        [pair stop];
        PrintError(interrupted ? @"Pairing cancelled." : @"Pairing timed out.");
        return 1;
    }
    if (_status != kIOReturnSuccess || !device.isPaired) {
        if (_status == kIOReturnUnsupported) {
            [pair stop];
        }
        PrintError(StatusMessage(@"Pairing did not create a Bluetooth bond", _status));
        return 1;
    }
    Print(@"Bluetooth pairing succeeded. Run watchrelay devices to select the watch.");
    return 0;
}

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)value {
    if (DeferToMainRunLoop(^{ [self devicePairingUserConfirmationRequest:sender numericValue:value]; })) {
        return;
    }
    _waitingForConfirmation = YES;
    Print([NSString stringWithFormat:@"Check for code %06u on the watch. If it matches, accept on the watch and type y here. Otherwise type n.", (unsigned)value]);
}

- (void)devicePairingUserPasskeyNotification:(id)sender passkey:(BluetoothPasskey)passkey {
    if (DeferToMainRunLoop(^{ [self devicePairingUserPasskeyNotification:sender passkey:passkey]; })) {
        return;
    }
    Print([NSString stringWithFormat:@"If the watch asks for a passkey, enter %06u on the watch.", (unsigned)passkey]);
}

- (void)devicePairingPINCodeRequest:(id)sender {
    if (DeferToMainRunLoop(^{ [self devicePairingPINCodeRequest:sender]; })) {
        return;
    }
    _done = YES;
    _status = kIOReturnUnsupported;
    PrintError(@"The device requested legacy PIN pairing. Use Bluetooth Settings if the watch displays a PIN.");
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    if (DeferToMainRunLoop(^{ [self devicePairingFinished:sender error:error]; })) {
        return;
    }
    if (!_done) {
        _status = error;
        _done = YES;
    }
}
@end

typedef NS_ENUM(NSInteger, ProbeStage) {
    StagePreparing,
    StageBaseband,
    StageDiscovering,
    StageOpening,
    StageAutoProof,
    StageApproval,
    StageAutoEnrollment,
    StageTesting,
    StageRelaying,
    StageFinished,
};

typedef void (^RelayFinished)(int status, NSString *code);

@interface RelayProbe : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property (readonly) BOOL relayWasReady;
@property (readonly) BOOL reconnectableFailure;
@property (readonly) BluetoothRFCOMMChannelID selectedChannel;
- (instancetype)initWithDevice:(IOBluetoothDevice *)device log:(ProbeLog *)log;
- (int)runWithExplicitBaseband:(BOOL)explicitBaseband knownChannel:(BluetoothRFCOMMChannelID)knownChannel
    proxyPort:(uint16_t)proxyPort enroll:(BOOL)enroll;
- (void)attachIncoming:(IOBluetoothRFCOMMChannel *)channel port:(uint16_t)port key:(NSData *)key finished:(RelayFinished)finished;
- (void)tick;
@end

@implementation RelayProbe {
    IOBluetoothDevice *_device;
    IOBluetoothSDPUUID *_serviceUUID;
    IOBluetoothRFCOMMChannel *_channel;
    RelayFrameDecoder *_decoder;
    ProbeLog *_log;
    ProbeStage _stage;
    NSTimeInterval _deadline;
    NSTimeInterval _pingSentAt;
    NSTimeInterval _nextPingAt;
    NSTimeInterval _lastValidFrameAt;
    NSUInteger _pingCount;
    NSUInteger _pingsDuringCellCheck;
    NSUInteger _bytesRead;
    NSUInteger _bytesWritten;
    NSData *_expectedPong;
    BOOL _cellRequested;
    BOOL _cellComplete;
    BOOL _cellSuccess;
    int _result;
    NSDate *_previousServicesUpdate;
    uint16_t _proxyPort;
    SocksProxy *_proxy;
    RelayFinished _finished;
    BOOL _enrolling;
    NSData *_autoKey;
    NSData *_macNonce;

    NSMutableDictionary<NSNumber *, NSMutableArray<NSData *> *> *_outgoing;
    NSMutableArray<NSNumber *> *_streamTurns;
    NSData *_activeWrite;
    NSUInteger _writeOffset;
    NSUInteger _writeInFlight;
    NSUInteger _queuedBytes;
    NSUInteger _queuedFrames;
    NSUInteger _queueHighWater;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)device log:(ProbeLog *)log {
    self = [super init];
    if (self) {
        _device = device;
        _decoder = [RelayFrameDecoder new];
        _log = log;
        _outgoing = [NSMutableDictionary dictionary];
        _streamTurns = [NSMutableArray array];
        uuid_t uuidBytes;
        [[[NSUUID alloc] initWithUUIDString:RelayServiceUUID] getUUIDBytes:uuidBytes];
        _serviceUUID = [IOBluetoothSDPUUID uuidWithBytes:uuidBytes length:sizeof(uuidBytes)];
    }
    return self;
}

- (void)finish:(int)result code:(NSString *)code message:(NSString *)message {
    if (_stage == StageFinished) {
        return;
    }
    _result = result;
    _stage = StageFinished;
    static NSSet<NSString *> *connectionFailures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        connectionFailures = [NSSet setWithArray:@[@"rfcomm_closed", @"rfcomm_write", @"heartbeat_timeout",
            @"rfcomm_timeout", @"rfcomm_open", @"rfcomm_start", @"sdp_start", @"sdp_failed", @"sdp_timeout", @"service_missing"]];
    });
    _reconnectableFailure = [connectionFailures containsObject:code];
    [_log event:@"probe_finished" fields:@{@"code": code, @"exit_code": @(result),
        @"matched_pongs": @(_pingCount), @"pongs_while_cell_pending": @(_pingsDuringCellCheck),
        @"bytes_read": @(_bytesRead), @"bytes_written": @(_bytesWritten),
        @"queue_high_water_bytes": @(_queueHighWater),
        @"cell_result_received": @(_cellComplete), @"cell_success": @(_cellSuccess)}];
    if (result == 0) {
        Print(message);
    } else {
        PrintError(message);
    }
    [_proxy stop];
    [_channel setDelegate:nil];
    [_channel closeChannel];
    [_outgoing removeAllObjects];
    [_streamTurns removeAllObjects];
    if (_finished) {
        RelayFinished callback = _finished;
        _finished = nil;
        callback(result, code);
    } else {
        CFRunLoopStop(CFRunLoopGetMain());
    }
}

- (void)bluetoothFailure:(NSString *)code message:(NSString *)message status:(IOReturn)status {
    [_log event:@"bluetooth_error" fields:@{@"code": code, @"status": @(status)}];
    [self finish:1 code:code message:StatusMessage(message, status)];
}

- (int)runWithExplicitBaseband:(BOOL)explicitBaseband knownChannel:(BluetoothRFCOMMChannelID)knownChannel
    proxyPort:(uint16_t)proxyPort enroll:(BOOL)enroll {
    _proxyPort = proxyPort;
    _enrolling = enroll;
    [_log event:@"probe_started" fields:@{@"bonded_at_start": @(_device.isPaired), @"connect_timeout_s": @(ConnectTimeout),
        @"approval_timeout_s": @(ApprovalTimeout), @"probe_timeout_s": @(ProbeTimeout),
        @"ping_timeout_s": @(PingTimeout), @"ping_interval_s": @1, @"ping_goal": @(PingGoal),
        @"relay_heartbeat_interval_s": @(RelayPingInterval), @"relay_idle_timeout_s": @(RelayIdleTimeout),
        @"run_loop": @"core_foundation", @"proxy_port": @(proxyPort), @"queue_limit_bytes": @(MaxQueuedBytes),
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString}];
    Print([NSString stringWithFormat:@"Diagnostics: %@", _log.url.path]);
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *unused) {
        (void)unused;
        @autoreleasepool { [self tick]; }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    NSTimer *warmup = [NSTimer timerWithTimeInterval:0.75 repeats:NO block:^(NSTimer *unused) {
        (void)unused;
        if (self->_stage == StagePreparing) {
            [self begin:explicitBaseband knownChannel:knownChannel];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:warmup forMode:NSRunLoopCommonModes];
    CFRunLoopRun();
    [timer invalidate];
    [warmup invalidate];
    return _result;
}

- (void)begin:(BOOL)explicitBaseband knownChannel:(BluetoothRFCOMMChannelID)knownChannel {
    if (knownChannel) {
        [_log event:@"observed_channel_selected" fields:@{@"rfcomm_channel": @(knownChannel)}];
        Print(@"Testing the RFCOMM channel observed in the watch's current Bluetooth diagnostics.");
        [self startChannel:knownChannel onDevice:_device];
    } else if (explicitBaseband && !_device.isConnected) {
        Print(@"Opening the authenticated Bluetooth link before checking the WatchRelay service.");
        _stage = StageBaseband;
        _deadline = Uptime() + ConnectTimeout;
        [_log event:@"baseband_connection_started" fields:@{}];
        IOReturn status = [_device openConnection:self withPageTimeout:0 authenticationRequired:YES];
        if (status != kIOReturnSuccess) {
            [self bluetoothFailure:@"baseband_start" message:@"Could not start the authenticated Bluetooth link" status:status];
        }
    } else {
        [self startSDP];
    }
}

- (void)attachIncoming:(IOBluetoothRFCOMMChannel *)channel port:(uint16_t)port key:(NSData *)key finished:(RelayFinished)finished {
    _finished = [finished copy];
    _proxyPort = port;
    _autoKey = key;
    _selectedChannel = [channel getChannelID];
    _channel = channel;
    _stage = StageOpening;
    _deadline = Uptime() + ConnectTimeout;
    [_log event:@"incoming_link_started" fields:@{@"rfcomm_channel": @(_selectedChannel),
        @"proxy_port": @(port), @"queue_limit_bytes": @(MaxQueuedBytes)}];
    IOReturn status = [channel setDelegate:self];
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"rfcomm_delegate" message:@"Could not receive data on the watch connection" status:status];
    } else if (channel.isOpen) {
        [self rfcommChannelOpenComplete:channel status:kIOReturnSuccess];
    }
}

- (void)startSDP {
    Print(@"Looking up the WatchRelay Bluetooth service. Keep the session started on the watch.");
    _stage = StageDiscovering;
    _deadline = Uptime() + ConnectTimeout;
    _previousServicesUpdate = [_device getLastServicesUpdate];
    [_log event:@"sdp_query_started" fields:@{@"mode": @"full", @"baseband_connected": @(_device.isConnected)}];
    IOReturn status = [_device performSDPQuery:self];
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"sdp_start" message:@"Could not start the Bluetooth service lookup" status:status];
    }
}

- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (DeferToMainRunLoop(^{ [self connectionComplete:device status:status]; })) {
        return;
    }
    if (_stage == StageBaseband) {
        if (status == kIOReturnSuccess || _device.isConnected) {
            [_log event:@"baseband_connection_complete" fields:@{@"status": @(status)}];
            [self startSDP];
        } else {
            [self bluetoothFailure:@"baseband_failed" message:@"The authenticated Bluetooth link failed" status:status];
        }
    }
}

- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (DeferToMainRunLoop(^{ [self sdpQueryComplete:device status:status]; })) {
        return;
    }
    if (_stage != StageDiscovering) {
        return;
    }
    [_log event:@"sdp_query_complete" fields:@{@"status": @(status), @"records": @(device.services.count)}];
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"sdp_failed" message:@"Bluetooth service lookup failed" status:status];
        return;
    }
    IOBluetoothSDPServiceRecord *record = [device getServiceRecordForUUID:_serviceUUID];
    if (!record) {
        [self finish:1 code:@"service_missing" message:@"The watch did not advertise WatchRelay. Start the watch session and retry."];
        return;
    }
    BluetoothRFCOMMChannelID channelID = 0;
    status = [record getRFCOMMChannelID:&channelID];
    if (status != kIOReturnSuccess || channelID == 0 || channelID > 30) {
        [self bluetoothFailure:@"invalid_channel" message:@"The WatchRelay service did not provide a usable RFCOMM channel" status:status];
        return;
    }
    [_log event:@"service_found" fields:@{@"rfcomm_channel": @(channelID)}];
    [self startChannel:channelID onDevice:device];
}

- (void)startChannel:(BluetoothRFCOMMChannelID)channelID onDevice:(IOBluetoothDevice *)device {
    _selectedChannel = channelID;
    _stage = StageOpening;
    _deadline = Uptime() + ConnectTimeout;
    IOBluetoothRFCOMMChannel *channel = nil;
    IOReturn status = [device openRFCOMMChannelAsync:&channel withChannelID:channelID delegate:self];
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"rfcomm_start" message:@"Could not start the RFCOMM connection" status:status];
    } else if (!_channel) {
        _channel = channel;
    }
}

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if (DeferToMainRunLoop(^{ [self rfcommChannelOpenComplete:channel status:status]; })) {
        return;
    }
    if (_stage != StageOpening) {
        return;
    }
    _channel = channel;
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"rfcomm_open" message:@"RFCOMM connection failed" status:status];
        return;
    }
    if (!_device.isPaired) {
        [self finish:1 code:@"watch_not_bonded" message:@"Pair the watch with this Mac in Bluetooth Settings and retry."];
        return;
    }
    [_log event:@"rfcomm_open" fields:@{@"mtu": @([channel getMTU])}];
    if (_autoKey) {
        _macNonce = AutoTrustRandom();
        _stage = StageAutoProof;
        _deadline = Uptime() + AutoAuthenticationTimeout;
        [self send:RelayAutoChallenge payload:_macNonce];
        return;
    }
    [self beginHello];
}

- (void)beginHello {
    if (_stage == StageFinished) {
        return;
    }
    Print(@"Bluetooth connected. Approve this Mac on the watch if asked.");
    _stage = StageApproval;
    _deadline = Uptime() + ApprovalTimeout;
    [self send:RelayHello payload:NSData.data];
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    if (DeferToMainRunLoop(^{ [self rfcommChannelClosed:channel]; })) {
        return;
    }
    if (_stage != StageFinished && channel == _channel) {
        [self finish:1 code:@"rfcomm_closed" message:_proxyPort
            ? @"Bluetooth disconnected. The local proxy has closed."
            : @"The watch closed the Bluetooth connection during the probe."];
    }
}

- (void)send:(RelayMessage)type payload:(NSData *)payload {
    [self send:type streamID:0 payload:payload];
}

- (void)send:(RelayMessage)type streamID:(uint32_t)streamID payload:(NSData *)payload {
    if (_stage == StageFinished) {
        return;
    }
    NSData *frame = RelayEncodeStream(type, streamID, payload);
    if (!frame || _queuedBytes + frame.length > MaxQueuedBytes || _queuedFrames >= MaxQueuedFrames) {
        [self finish:1 code:@"write_queue" message:@"The Bluetooth write queue reached its limit."];
        return;
    }
    NSNumber *key = @(streamID);
    NSMutableArray<NSData *> *lane = _outgoing[key];
    if (!lane) {
        lane = [NSMutableArray array];
        _outgoing[key] = lane;
        if (streamID) {
            [_streamTurns addObject:key];
        }
    }
    [lane addObject:frame];
    _queuedBytes += frame.length;
    _queuedFrames++;
    _queueHighWater = MAX(_queueHighWater, _queuedBytes);
    [self writeNextChunk];
}

- (NSData *)nextWriteFrame {
    NSNumber *key = @0;
    NSMutableArray<NSData *> *lane = _outgoing[key];
    if (!lane) {
        key = _streamTurns.firstObject;
        if (!key) {
            return nil;
        }
        lane = _outgoing[key];
        [_streamTurns removeObjectAtIndex:0];
    }
    NSData *frame = lane.firstObject;
    [lane removeObjectAtIndex:0];
    if (!lane.count) {
        [_outgoing removeObjectForKey:key];
    } else if (key.unsignedIntValue) {
        [_streamTurns addObject:key];
    }
    return frame;
}

- (void)writeNextChunk {
    if (_stage == StageFinished || _writeInFlight) {
        return;
    }
    if (!_activeWrite) {
        _activeWrite = [self nextWriteFrame];
    }
    NSData *frame = _activeWrite;
    if (!frame) {
        return;
    }
    _writeInFlight = MIN(frame.length - _writeOffset, [_channel getMTU]);
    if (!_writeInFlight) {
        [self finish:1 code:@"invalid_mtu" message:@"The Bluetooth channel reported an invalid frame size."];
        return;
    }
    const uint8_t *bytes = frame.bytes;
    // The queue retains the frame until the corresponding completion callback.
    IOReturn status = [_channel writeAsync:(void *)(bytes + _writeOffset) length:(UInt16)_writeInFlight refcon:NULL];
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"rfcomm_write" message:@"Bluetooth write failed" status:status];
    }
}

- (void)rfcommChannelWriteComplete:(IOBluetoothRFCOMMChannel *)channel refcon:(void *)refcon status:(IOReturn)status {
    if (DeferToMainRunLoop(^{ [self rfcommChannelWriteComplete:channel refcon:refcon status:status]; })) {
        return;
    }
    if (_stage == StageFinished || channel != _channel) {
        return;
    }
    if (status != kIOReturnSuccess) {
        [self bluetoothFailure:@"rfcomm_write" message:@"Bluetooth write failed" status:status];
        return;
    }
    _bytesWritten += _writeInFlight;
    _writeOffset += _writeInFlight;
    _writeInFlight = 0;
    if (_writeOffset == _activeWrite.length) {
        _queuedBytes -= _writeOffset;
        _queuedFrames--;
        _activeWrite = nil;
        _writeOffset = 0;
    }
    [self writeNextChunk];
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    if (!NSThread.isMainThread) {
        NSData *copy = [NSData dataWithBytes:data length:length];
        DeferToMainRunLoop(^{ [self rfcommChannelData:channel data:(void *)copy.bytes length:copy.length]; });
        return;
    }
    if (_stage == StageFinished || channel != _channel) {
        return;
    }
    _bytesRead += length;
    BOOL valid = [_decoder appendBytes:data length:length handler:^(RelayMessage type, uint32_t streamID, NSData *payload) {
        [self receive:type streamID:streamID payload:payload];
    }];
    if (!valid) {
        [self finish:1 code:@"invalid_frame" message:@"The watch sent an invalid probe frame."];
    }
}

- (void)receive:(RelayMessage)type streamID:(uint32_t)streamID payload:(NSData *)payload {
    if (_stage == StageFinished) {
        return;
    }
    if (streamID != 0) {
        if (_stage == StageRelaying && [_proxy receive:type streamID:streamID payload:payload]) {
            _lastValidFrameAt = Uptime();
        } else {
            [self finish:1 code:@"invalid_stream_frame" message:@"The watch sent an invalid relay message."];
        }
        return;
    }
    if (_stage == StageAutoProof && type == RelayAutoProof) {
        NSData *watchNonce = [payload subdataWithRange:NSMakeRange(0, 32)];
        NSData *proof = [payload subdataWithRange:NSMakeRange(32, 32)];
        NSData *expected = AutoTrustProof(_autoKey, AutoWatchProofContext, _macNonce, watchNonce);
        if (!AutoTrustMatches(proof, expected)) {
            [self finish:1 code:@"auto_invalid_proof" message:@"Automatic connection verification failed. Enroll the paired watch again if its app was reset."];
            return;
        }
        NSData *accept = AutoTrustProof(_autoKey, AutoMacProofContext, _macNonce, watchNonce);
        _macNonce = nil;
        [_log event:@"auto_proof_verified" fields:@{}];
        [self send:RelayAutoAccept payload:accept];
        [self beginHello];
        return;
    }
    if (_stage == StageAutoEnrollment && type == RelayAutoEnrolled) {
        NSError *error = nil;
        if (!AutoTrustWriteKey(NormalizeAddress(_device.addressString), _autoKey, &error)) {
            NSString *message = [NSString stringWithFormat:@"The watch saved enrollment, but the Mac could not save its key. %@ Run enrollment again.",
                error.localizedDescription];
            [self finish:1 code:@"auto_save_failed" message:message];
            return;
        }
        [_log event:@"auto_enrolled" fields:@{}];
        [self finish:0 code:@"auto_enrolled" message:@"Automatic connection enrollment is complete."];
        return;
    }
    if (_stage == StageApproval && type == RelayHelloAck) {
        [_log event:@"watch_approved" fields:@{}];
        if (_enrolling) {
            _autoKey = AutoTrustRandom();
            _stage = StageAutoEnrollment;
            _deadline = Uptime() + AutoAuthenticationTimeout;
            [self send:RelayAutoEnroll payload:_autoKey];
            return;
        } else if (_proxyPort) {
            [self startProxy];
            return;
        }
        _stage = StageTesting;
        _deadline = Uptime() + ProbeTimeout;
        _nextPingAt = Uptime();
        [self tick];
        return;
    }
    if (_stage == StageRelaying && type == RelayPong && [_expectedPong isEqualToData:payload]) {
        _expectedPong = nil;
        _lastValidFrameAt = Uptime();
        return;
    }
    if (_stage == StageTesting && type == RelayPong && [_expectedPong isEqualToData:payload]) {
        _pingCount++;
        BOOL cellPending = _cellRequested && !_cellComplete;
        if (cellPending) {
            _pingsDuringCellCheck++;
        }
        [_log event:@"pong_matched" fields:@{@"number": @(_pingCount), @"cell_pending": @(cellPending),
            @"rtt_ms": @((Uptime() - _pingSentAt) * 1000)}];
        _expectedPong = nil;
        if (_pingCount == 1) {
            _cellRequested = YES;
            _nextPingAt = Uptime();
            [_log event:@"cell_probe_requested" fields:@{}];
            Print(@"Bluetooth echo passed. Checking the watch's cellular HTTPS connection while echoes continue.");
            [self send:RelayCellProbe payload:NSData.data];
        }
        return;
    }
    if (_stage == StageTesting && type == RelayCellResult && _cellRequested && !_cellComplete) {
        const uint8_t *bytes = payload.bytes;
        NSString *detail = [[NSString alloc] initWithBytes:bytes + 1 length:payload.length - 1 encoding:NSUTF8StringEncoding];
        if (bytes[0] <= 1 && detail) {
            _cellComplete = YES;
            _cellSuccess = bytes[0] == 1;
            [_log event:@"cell_result" fields:@{@"success": @(_cellSuccess)}];
            NSString *printable = Printable(detail);
            Print([NSString stringWithFormat:@"Watch cellular result: %@%@", _cellSuccess ? @"passed" : @"failed",
                printable.length ? [@" — " stringByAppendingString:printable] : @""]);
            return;
        }
    }
    [self finish:1 code:@"unexpected_message" message:@"The watch sent an unexpected probe message or an incorrect Bluetooth echo."];
}

- (void)startProxy {
    __weak RelayProbe *weakSelf = self;
    ProbeLog *log = _log;
    BOOL wideMode = [NSProcessInfo.processInfo.environment[@"WATCHRELAY_WIDE"] isEqualToString:@"1"];
    _proxy = [[SocksProxy alloc] initWithSend:^(RelayMessage type, uint32_t streamID, NSData *payload) {
        [weakSelf send:type streamID:streamID payload:payload];
    } log:^(NSString *event, NSDictionary *fields) {
        [log event:event fields:fields];
    } wideMode:wideMode clock:nil];
    NSError *error = nil;
    if (![_proxy startOnPort:_proxyPort error:&error]) {
        NSString *message = [NSString stringWithFormat:@"Could not listen on 127.0.0.1:%u. %@", _proxyPort, error.localizedDescription];
        [self finish:1 code:@"bind_failed" message:message];
        return;
    }
    _stage = StageRelaying;
    _relayWasReady = YES;
    _lastValidFrameAt = Uptime();
    _nextPingAt = _lastValidFrameAt + RelayPingInterval;
    Print([NSString stringWithFormat:@"SOCKS5 relay ready on 127.0.0.1:%u. Up to %lu connections. Press Ctrl-C to stop.",
        _proxyPort, (unsigned long)_proxy.streamLimit]);
}

- (void)tickProxy:(NSTimeInterval)now {
    if (now - _lastValidFrameAt >= RelayIdleTimeout) {
        [self finish:1 code:@"heartbeat_timeout" message:@"The watch stopped responding. The local proxy has closed."];
        return;
    }
    if (!_expectedPong && now >= _nextPingAt) {
        uint8_t payload[16];
        arc4random_buf(payload, sizeof(payload));
        _expectedPong = [NSData dataWithBytes:payload length:sizeof(payload)];
        _pingSentAt = now;
        _nextPingAt = now + RelayPingInterval;
        [self send:RelayPing payload:_expectedPong];
    }
    [_proxy tick];
}

- (void)tick {
    if (_stage == StageFinished) {
        return;
    }
    if (interrupted) {
        [self finish:130 code:@"cancelled" message:_proxyPort ? @"Relay stopped." : @"Probe cancelled."];
        return;
    }
    if (_stage == StagePreparing) {
        return;
    }
    NSTimeInterval now = Uptime();
    if (_stage == StageRelaying) {
        [self tickProxy:now];
        return;
    }
    if (_stage == StageBaseband && _device.isConnected) {
        [_log event:@"baseband_connection_observed" fields:@{}];
        [self startSDP];
        return;
    }
    if (_stage == StageDiscovering) {
        NSDate *update = [_device getLastServicesUpdate];
        if (update && (!_previousServicesUpdate || [update compare:_previousServicesUpdate] == NSOrderedDescending)
            && [_device getServiceRecordForUUID:_serviceUUID]) {
            [_log event:@"sdp_update_observed" fields:@{}];
            [self sdpQueryComplete:_device status:kIOReturnSuccess];
            return;
        }
    }
    if (now >= _deadline) {
        switch (_stage) {
            case StagePreparing:
                break;
            case StageBaseband:
                [self finish:1 code:@"baseband_timeout" message:@"The authenticated Bluetooth link did not open in time."];
                break;
            case StageDiscovering:
                [self finish:1 code:@"sdp_timeout" message:@"Bluetooth service lookup timed out."];
                break;
            case StageOpening:
                [self finish:1 code:@"rfcomm_timeout" message:@"The Bluetooth channel did not open in time."];
                break;
            case StageAutoProof:
                [self finish:1 code:@"auto_proof_timeout" message:@"The watch did not verify the automatic connection in time."];
                break;
            case StageApproval:
                [self finish:1 code:@"approval_timeout" message:@"No watch approval arrived. Open WatchRelay and approve this Mac."];
                break;
            case StageAutoEnrollment:
                [self finish:1 code:@"auto_enroll_timeout" message:@"The watch did not confirm enrollment in time. Keep the app open and try again."];
                break;
            case StageTesting:
                [self finish:1 code:@"probe_timeout" message:@"The watch did not finish the echo and cellular tests in time."];
                break;
            case StageRelaying:
                break;
            case StageFinished:
                break;
        }
        return;
    }
    if (_stage != StageTesting) {
        return;
    }
    if (_cellComplete && _pingCount >= PingGoal && !_expectedPong) {
        NSString *message = [NSString stringWithFormat:@"%lu Bluetooth echoes matched, including %lu while the cellular result was pending.",
            _pingCount, _pingsDuringCellCheck];
        [self finish:_cellSuccess ? 0 : 2 code:_cellSuccess ? @"passed" : @"cellular_failed" message:message];
        return;
    }
    if (_expectedPong && now - _pingSentAt >= PingTimeout) {
        [self finish:1 code:@"echo_timeout" message:@"A Bluetooth echo did not return within five seconds."];
        return;
    }
    if (!_expectedPong && now >= _nextPingAt) {
        uint8_t payload[32];
        arc4random_buf(payload, sizeof(payload));
        _expectedPong = [NSData dataWithBytes:payload length:sizeof(payload)];
        _pingSentAt = now;
        _nextPingAt = now + 1;
        [self send:RelayPing payload:_expectedPong];
    }
}
@end

static int RunAutomaticDevice(IOBluetoothDevice *device, uint16_t port) {
    NSError *error = nil;
    NSData *key = AutoTrustReadKey(NormalizeAddress(device.addressString), &error);
    if (error) {
        PrintError([NSString stringWithFormat:@"Could not read this watch's enrollment key. %@", error.localizedDescription]);
        return 1;
    }
    ProbeLog *listenerLog = [[ProbeLog alloc] initWithError:&error];
    if (!listenerLog) {
        PrintError([NSString stringWithFormat:@"Could not create a listener diagnostics file: %@", error.localizedDescription]);
        return 1;
    }
    Print([NSString stringWithFormat:@"Listener diagnostics: %@", listenerLog.url.path]);
    __block RelayProbe *active = nil;
    // Keep the most recent closed channel buffer alive during any late callbacks.
    NSMutableArray<RelayProbe *> *retired = [NSMutableArray arrayWithCapacity:1];
    __block int result = 0;
    IncomingRfcomm *listener = [[IncomingRfcomm alloc] initWithDevice:device serviceUUID:RelayServiceUUID
        allowApplicationAuthentication:key != nil opened:^(IOBluetoothRFCOMMChannel *channel) {
        @autoreleasepool {
            if (active || interrupted) {
                [channel closeChannel];
                return;
            }
            NSError *linkError = nil;
            ProbeLog *linkLog = [[ProbeLog alloc] initWithError:&linkError];
            if (!linkLog) {
                PrintError([NSString stringWithFormat:@"Could not create a link diagnostics file: %@", linkError.localizedDescription]);
                [channel closeChannel];
                result = 1;
                CFRunLoopStop(CFRunLoopGetMain());
                return;
            }
            Print([NSString stringWithFormat:@"Link diagnostics: %@", linkLog.url.path]);
            active = [[RelayProbe alloc] initWithDevice:device log:linkLog];
            [active attachIncoming:channel port:port key:key finished:^(int status, NSString *code) {
                [retired removeAllObjects];
                [retired addObject:active];
                active = nil;
                [listenerLog event:@"incoming_link_finished" fields:@{@"code": code}];
                if (interrupted || [code isEqualToString:@"bind_failed"]) {
                    result = status;
                    CFRunLoopStop(CFRunLoopGetMain());
                } else {
                    Print(@"Waiting for the watch to reconnect. Interrupted TCP requests were closed.");
                }
            }];
        }
    }];
    NSTimer *warmup = [NSTimer timerWithTimeInterval:0.75 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        NSError *listenError = nil;
        if (![listener startWithError:&listenError]) {
            PrintError([NSString stringWithFormat:@"Could not publish the Mac's Bluetooth service. %@", listenError.localizedDescription]);
            [listenerLog event:@"incoming_listen_failed" fields:@{@"error_code": @(listenError.code)}];
            result = 1;
            CFRunLoopStop(CFRunLoopGetMain());
            return;
        }
        [listenerLog event:@"incoming_listening" fields:@{@"rfcomm_channel": @(listener.channelID),
            @"proxy_port": @(port), @"auth_method": key ? @"shared_key" : @"platform"}];
        Print(@"Waiting for the paired watch. Start automatic connection in WatchRelay on the watch.");
        if (!key) {
            Print(@"This watch has no enrollment key. If macOS cannot verify Bluetooth encryption, run the one-time enroll command.");
        }
    }];
    NSTimer *poll = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        @autoreleasepool {
            if (active) {
                [active tick];
            } else if (interrupted) {
                result = 130;
                CFRunLoopStop(CFRunLoopGetMain());
            }
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:warmup forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:poll forMode:NSRunLoopCommonModes];
    CFRunLoopRun();
    [warmup invalidate];
    [poll invalidate];
    [listener stop];
    [retired removeAllObjects];
    [listenerLog event:@"incoming_listener_finished" fields:@{@"exit_code": @(result)}];
    return result;
}

static int RunSelectedDevice(IOBluetoothDevice *device, BOOL explicitBaseband, BluetoothRFCOMMChannelID channel,
    uint16_t port, BOOL enroll) {
    const NSTimeInterval backoff[] = {0.5, 1, 2, 4, 8};
    const NSUInteger attempts = sizeof(backoff) / sizeof(backoff[0]);
    BOOL established = NO;
    BluetoothRFCOMMChannelID lastGoodChannel = 0;
    // The SDK can deliver a late SDP callback. Keep bounded retired sessions alive until exit.
    NSMutableArray<RelayProbe *> *sessions = [NSMutableArray arrayWithCapacity:attempts + 1];
    for (NSUInteger attempt = 0; attempt <= attempts; attempt++) {
        @autoreleasepool {
            NSError *error = nil;
            ProbeLog *log = [[ProbeLog alloc] initWithError:&error];
            if (!log) {
                PrintError([NSString stringWithFormat:@"Could not create a desktop diagnostics file: %@", error.localizedDescription]);
                return 1;
            }
            RelayProbe *session = [[RelayProbe alloc] initWithDevice:device log:log];
            [sessions addObject:session];
            BluetoothRFCOMMChannelID selected = attempt == 0 ? channel : (attempt == 3 ? 0 : lastGoodChannel);
            int result = [session runWithExplicitBaseband:explicitBaseband knownChannel:selected proxyPort:port enroll:enroll];
            if (session.relayWasReady) {
                established = YES;
                lastGoodChannel = session.selectedChannel;
            }
            if (!port || !established || !session.reconnectableFailure || interrupted) {
                return result;
            }
            if (attempt == attempts) {
                PrintError(@"Could not reconnect. Check the watch session and its current Bluetooth channel.");
                return result;
            }
            NSTimeInterval delay = backoff[attempt];
            [log event:@"reconnect_scheduled" fields:@{@"attempt": @(attempt + 1), @"delay_seconds": @(delay)}];
            Print([NSString stringWithFormat:@"Reconnecting Bluetooth in %.1f seconds (%lu of %lu).",
                delay, attempt + 1, attempts]);
            NSTimeInterval until = Uptime() + delay;
            while (!interrupted && Uptime() < until) {
                RunLoopTick();
            }
            if (interrupted) {
                return 130;
            }
        }
    }
    return 1;
}

static void Usage(void) {
    Print(@"Usage: watchrelay doctor | devices | scan | pair <Bluetooth address> | probe [--baseband] <paired number or Bluetooth address> | diagnostics");
    Print(@"Diagnostic: watchrelay probe-channel <Bluetooth address> <observed RFCOMM channel>");
    Print(@"Relay: watchrelay start <paired number or Bluetooth address> [port]");
    Print(@"Automatic relay: watchrelay auto <paired number or Bluetooth address> [port]");
    Print(@"One-time automatic enrollment: watchrelay enroll <paired number or Bluetooth address> <observed RFCOMM channel>");
    Print(@"Diagnostic: watchrelay start-channel <paired number or Bluetooth address> <observed RFCOMM channel> [port]");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        signal(SIGINT, Interrupt);
        signal(SIGTERM, Interrupt);
        if (argc < 2) {
            Usage();
            return 64;
        }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if (argc == 2 && [command isEqualToString:@"diagnostics"]) {
            Print(DiagnosticsFolder().path);
            return 0;
        }
        if (argc == 2 && [command isEqualToString:@"doctor"]) {
            Print([NSString stringWithFormat:@"macOS %@", NSProcessInfo.processInfo.operatingSystemVersionString]);
            Print([NSString stringWithFormat:@"WatchRelay %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"dev"]);
            if (!BluetoothReady()) {
                return 1;
            }
            Print([NSString stringWithFormat:@"Classic Bluetooth adapter is on. Paired devices: %lu.", PairedDevices().count]);
            return 0;
        }
        if (argc == 2 && [command isEqualToString:@"devices"]) {
            if (!BluetoothReady()) {
                return 1;
            }
            PrintDevices(PairedDevices());
            return 0;
        }
        if (argc == 2 && [command isEqualToString:@"scan"]) {
            return BluetoothReady() ? Scan() : 1;
        }
        if (argc == 3 && [command isEqualToString:@"pair"]) {
            NSString *address = NormalizeAddress([NSString stringWithUTF8String:argv[2]]);
            if (!address) {
                PrintError(@"Enter the watch's exact Classic Bluetooth address from watchrelay scan.");
                return 64;
            }
            if (!BluetoothReady()) {
                return 1;
            }
            return [[DevicePairing new] run:[IOBluetoothDevice deviceWithAddressString:address]];
        }
        BOOL explicitBaseband = argc == 4 && !strcmp(argv[2], "--baseband");
        BOOL enroll = argc == 4 && [command isEqualToString:@"enroll"];
        BOOL directStart = (argc == 4 || argc == 5) && [command isEqualToString:@"start-channel"];
        BOOL directChannel = enroll || directStart || (argc == 4 && [command isEqualToString:@"probe-channel"]);
        BOOL automatic = (argc == 3 || argc == 4) && [command isEqualToString:@"auto"];
        BOOL relay = directStart || automatic || ((argc == 3 || argc == 4) && [command isEqualToString:@"start"]);
        if (((argc == 3 || explicitBaseband) && [command isEqualToString:@"probe"]) || directChannel || relay) {
            if (!BluetoothReady()) {
                return 1;
            }
            NSString *selection = [NSString stringWithUTF8String:argv[(directChannel || relay) ? 2 : argc - 1]];
            NSInteger channel = 0;
            NSInteger port = relay ? 1080 : 0;
            int portIndex = directStart ? 4 : 3;
            if (relay && argc > portIndex) {
                NSString *value = [NSString stringWithUTF8String:argv[portIndex]];
                NSScanner *scanner = value ? [NSScanner scannerWithString:value] : nil;
                if (![scanner scanInteger:&port] || !scanner.isAtEnd || port < 1 || port > 65535) {
                    PrintError(@"Enter a loopback port from 1 to 65535.");
                    return 64;
                }
            }
            if (directChannel) {
                NSString *value = [NSString stringWithUTF8String:argv[3]];
                NSScanner *scanner = value ? [NSScanner scannerWithString:value] : nil;
                if ((!directStart && !enroll && !NormalizeAddress(selection)) || ![scanner scanInteger:&channel]
                    || !scanner.isAtEnd || channel < 1 || channel > 30) {
                    PrintError((directStart || enroll)
                        ? @"Select a paired watch and enter its currently observed RFCOMM channel from 1 to 30."
                        : @"Enter the watch's exact Bluetooth address and the currently observed RFCOMM channel from 1 to 30.");
                    return 64;
                }
            }
            IOBluetoothDevice *device = SelectDevice(selection);
            if (!device) {
                PrintError(@"Select a watch from watchrelay devices or enter its Classic Bluetooth address.");
                return 64;
            }
            if ((directChannel || relay) && !device.isPaired) {
                PrintError(@"Pair the watch before running this Bluetooth diagnostic.");
                return 1;
            }
            return automatic ? RunAutomaticDevice(device, (uint16_t)port)
                : RunSelectedDevice(device, explicitBaseband, (BluetoothRFCOMMChannelID)channel, (uint16_t)port, enroll);
        }
        Usage();
        return 64;
    }
}
