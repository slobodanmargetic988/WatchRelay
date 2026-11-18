#import "SocksProxy.h"

#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSUInteger BrowserStreamLimit = 8;
static const NSUInteger WideStreamLimit = 24;
static const NSUInteger WideWaitingLimit = 96;
static const uint32_t StreamCredit = 65536;
static const size_t MaxData = 16384;
static const NSTimeInterval HandshakeTimeout = 12;
static const NSTimeInterval OpenTimeout = 40;
static const NSTimeInterval DrainTimeout = 10;
static const NSTimeInterval IdleTimeout = 75;
static const NSTimeInterval PressureIdleTimeout = 15;
static const NSTimeInterval WideBurstIdleTimeout = 6;
static const NSTimeInterval BrowserAdmissionTimeout = 8;
static const NSTimeInterval WideAdmissionTimeout = 12;

typedef NS_ENUM(NSInteger, ClientStage) {
    ClientGreeting,
    ClientMethods,
    ClientRequest,
    ClientDomainLength,
    ClientAddress,
    ClientOpening,
    ClientStreaming,
    ClientDraining,
};

@interface ClientWrite : NSObject
@property NSMutableData *bytes;
@property BOOL credited;
@end
@implementation ClientWrite
@end

static NSData *Bytes(const uint8_t *data, NSUInteger length) {
    return [NSData dataWithBytes:data length:length];
}

static NSData *SingleByte(uint8_t value) {
    return Bytes(&value, 1);
}

static NSTimeInterval Uptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static BOOL RetryableSocketError(void) {
    return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
}

static BOOL ConfigureSocket(int fd) {
    int flags = fcntl(fd, F_GETFL);
    int suppress = 1;
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, sizeof(suppress)) == 0;
}

static void ResetSocket(int fd) {
    struct linger reset = {.l_onoff = 1, .l_linger = 0};
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset));
    close(fd);
}

@interface SocksAdmission : NSObject
@property (readonly) NSTimeInterval queuedAt;
- (instancetype)initWithSocket:(int)socket queuedAt:(NSTimeInterval)now;
- (BOOL)disconnected;
- (int)takeSocket;
- (void)reject;
@end

@implementation SocksAdmission {
    int _socket;
}

- (instancetype)initWithSocket:(int)socket queuedAt:(NSTimeInterval)now {
    self = [super init];
    if (self) {
        _socket = socket;
        _queuedAt = now;
    }
    return self;
}

- (BOOL)disconnected {
    uint8_t byte;
    ssize_t count = recv(_socket, &byte, sizeof(byte), MSG_PEEK);
    return count == 0 || (count < 0 && !RetryableSocketError());
}

- (int)takeSocket {
    int socket = _socket;
    _socket = -1;
    return socket;
}

- (void)reject {
    if (_socket >= 0) {
        ResetSocket([self takeSocket]);
    }
}

- (void)dealloc {
    [self reject];
}
@end

@interface SocksProxy (StreamOperations)
- (NSTimeInterval)now;
- (uint32_t)allocateStream;
- (void)retireStream:(uint32_t)streamID aborted:(BOOL)aborted;
@end

@interface SocksClient : NSObject
@property (readonly) uint32_t streamID;
@property (readonly) BOOL closed;
@property (readonly) NSTimeInterval lastProgress;
- (instancetype)initWithSocket:(int)client owner:(SocksProxy *)owner send:(RelayFrameHandler)send log:(SocksProxyLog)log;
- (void)tick;
- (void)dropClient:(NSString *)reason;
- (BOOL)canEvictAt:(NSTimeInterval)now idleFor:(NSTimeInterval)idleTimeout;
- (void)evictForCapacity;
- (BOOL)receive:(RelayMessage)type payload:(NSData *)payload increment:(uint32_t)increment;
@end

@implementation SocksClient {
    __weak SocksProxy *_owner;
    RelayFrameHandler _send;
    SocksProxyLog _log;
    int _client;
    ClientStage _stage;
    NSTimeInterval _deadline;
    uint32_t _streamID;

    NSMutableData *_handshake;
    NSUInteger _need;
    uint8_t _command;
    uint8_t _addressType;
    NSUInteger _domainLength;
    NSMutableArray<ClientWrite *> *_writes;
    NSUInteger _writeOffset;
    uint32_t _txCredit;
    uint32_t _rxCredit;
    BOOL _clientEOF;
    BOOL _watchEOF;
    BOOL _clientOutputShutdown;
    uint64_t _sentBytes;
    uint64_t _deliveredBytes;
}

- (instancetype)initWithSocket:(int)client owner:(SocksProxy *)owner send:(RelayFrameHandler)send log:(SocksProxyLog)log {
    self = [super init];
    if (self) {
        _owner = owner;
        _send = [send copy];
        _log = [log copy];
        _client = client;
        _handshake = [NSMutableData data];
        _writes = [NSMutableArray array];
        _deadline = [_owner now] + HandshakeTimeout;
        [self expect:2 stage:ClientGreeting];
    }
    return self;
}

- (BOOL)closed {
    return _client < 0;
}

- (void)dealloc {
    if (_client >= 0) {
        close(_client);
    }
}

- (void)retire:(NSString *)reason aborted:(BOOL)aborted {
    if (_streamID) {
        [_owner retireStream:_streamID aborted:aborted];
        _log(@"stream_finished", @{@"stream": @(_streamID), @"code": reason,
            @"bytes_to_watch": @(_sentBytes), @"bytes_to_client": @(_deliveredBytes)});
    }
    _streamID = 0;
}

- (void)dropClient:(NSString *)reason {
    if (_client >= 0) {
        close(_client);
        _client = -1;
    }
    [self retire:reason aborted:YES];
    [_writes removeAllObjects];
    _writeOffset = 0;
    _handshake.length = 0;
}

- (void)abortClient:(uint8_t)code reason:(NSString *)reason {
    uint32_t streamID = _streamID;
    [self dropClient:reason];
    if (streamID) {
        _send(RelayClose, streamID, SingleByte(code));
    }
}

- (BOOL)canEvictAt:(NSTimeInterval)now idleFor:(NSTimeInterval)idleTimeout {
    if (_client < 0 || _stage != ClientStreaming || _clientEOF || _watchEOF ||
        _writes.count || _txCredit != StreamCredit || _rxCredit != StreamCredit ||
        now - _lastProgress < idleTimeout) {
        return NO;
    }
    // A read-ready socket might be sending new bytes or half-closing.
    uint8_t byte;
    return recv(_client, &byte, sizeof(byte), MSG_PEEK) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);
}

- (void)evictForCapacity {
    [self abortClient:2 reason:@"idle_evicted"];
}

- (void)queue:(NSData *)data credited:(BOOL)credited {
    ClientWrite *last = _writes.lastObject;
    if (credited && last.credited && last.bytes.length + data.length <= MaxData) {
        [last.bytes appendData:data];
        return;
    }
    ClientWrite *write = [ClientWrite new];
    write.bytes = [data mutableCopy];
    write.credited = credited;
    [_writes addObject:write];
}

- (void)drain {
    _stage = ClientDraining;
    _deadline = [_owner now] + DrainTimeout;
}

- (void)socksFailure:(uint8_t)code {
    const uint8_t reply[] = {5, code, 0, 1, 0, 0, 0, 0, 0, 0};
    [self queue:Bytes(reply, sizeof(reply)) credited:NO];
    [self drain];
}

- (void)expect:(NSUInteger)count stage:(ClientStage)stage {
    _handshake.length = 0;
    _need = count;
    _stage = stage;
}

- (void)handleHandshake {
    const uint8_t *bytes = _handshake.bytes;
    switch (_stage) {
        case ClientGreeting:
            if (bytes[0] != 5) {
                [self dropClient:@"invalid_socks_version"];
            } else if (bytes[1]) {
                [self expect:bytes[1] stage:ClientMethods];
            } else {
                const uint8_t reply[] = {5, 255};
                [self queue:Bytes(reply, sizeof(reply)) credited:NO];
                [self drain];
            }
            break;
        case ClientMethods: {
            BOOL supported = memchr(bytes, 0, _handshake.length) != NULL;
            const uint8_t reply[] = {5, supported ? 0 : 255};
            [self queue:Bytes(reply, sizeof(reply)) credited:NO];
            if (supported) {
                [self expect:4 stage:ClientRequest];
            } else {
                [self drain];
            }
            break;
        }
        case ClientRequest:
            if (bytes[0] != 5 || bytes[2] != 0) {
                [self socksFailure:1];
            } else {
                _command = bytes[1];
                _addressType = bytes[3];
                _domainLength = 0;
                switch (_addressType) {
                    case 1:
                        [self expect:6 stage:ClientAddress];
                        break;
                    case 3:
                        [self expect:1 stage:ClientDomainLength];
                        break;
                    case 4:
                        [self expect:18 stage:ClientAddress];
                        break;
                    default:
                        [self socksFailure:8];
                        break;
                }
            }
            break;
        case ClientDomainLength:
            if (!bytes[0]) {
                [self socksFailure:8];
            } else {
                _domainLength = bytes[0];
                [self expect:_domainLength + 2 stage:ClientAddress];
            }
            break;
        case ClientAddress:
            [self openDestination];
            break;
        case ClientOpening:
        case ClientStreaming:
        case ClientDraining:
            break;
    }
}

- (void)openDestination {
    if (_command != 1) {
        [self socksFailure:7];
        return;
    }
    const uint8_t *bytes = _handshake.bytes;
    for (NSUInteger index = 0; index < _domainLength; index++) {
        if (bytes[index] <= 32 || bytes[index] >= 127) {
            [self socksFailure:8];
            return;
        }
    }
    NSUInteger length = _handshake.length;
    if (!bytes[length - 2] && !bytes[length - 1]) {
        [self socksFailure:1];
        return;
    }
    NSMutableData *address = [NSMutableData dataWithBytes:&_addressType length:1];
    if (_addressType == 3) {
        uint8_t domainLength = (uint8_t)_domainLength;
        [address appendBytes:&domainLength length:1];
    }
    [address appendData:_handshake];
    _streamID = [_owner allocateStream];
    if (!_streamID) {
        [self socksFailure:1];
        return;
    }
    _stage = ClientOpening;
    _deadline = [_owner now] + OpenTimeout;
    _log(@"stream_open", @{@"stream": @(_streamID), @"address_type": @(_addressType)});
    _send(RelayOpen, _streamID, address);
}

- (void)readClient {
    uint8_t data[16384];
    if (_stage < ClientOpening) {
        while (_client >= 0 && _stage < ClientOpening) {
            ssize_t count = recv(_client, data, _need - _handshake.length, 0);
            if (count <= 0) {
                if (count == 0 || !RetryableSocketError()) {
                    [self dropClient:@"handshake_closed"];
                }
                break;
            }
            [_handshake appendBytes:data length:(NSUInteger)count];
            if (_handshake.length == _need) {
                [self handleHandshake];
            }
        }
        return;
    }
    if (_stage == ClientOpening) {
        // Peek for a reset while the watch is opening. A FIN still permits a reply.
        if (recv(_client, data, 1, MSG_PEEK) < 0 && !RetryableSocketError()) {
            [self abortClient:2 reason:@"client_cancelled"];
        }
        return;
    }
    if (_stage != ClientStreaming || _clientEOF || !_txCredit) {
        return;
    }
    ssize_t count = recv(_client, data, MIN(MaxData, _txCredit), 0);
    if (count > 0) {
        _lastProgress = [_owner now];
        _txCredit -= (uint32_t)count;
        _sentBytes += (uint64_t)count;
        _send(RelayData, _streamID, Bytes(data, (NSUInteger)count));
    } else if (count == 0) {
        _lastProgress = [_owner now];
        _clientEOF = YES;
        _send(RelayHalfClose, _streamID, NSData.data);
    } else if (!RetryableSocketError()) {
        [self abortClient:2 reason:@"client_read"];
    }
}

- (void)flushClient {
    uint32_t delivered = 0;
    size_t budget = MaxData;
    while (budget && _writes.count && _client >= 0) {
        ClientWrite *write = _writes.firstObject;
        const uint8_t *bytes = write.bytes.bytes;
        ssize_t count = send(_client, bytes + _writeOffset, MIN(write.bytes.length - _writeOffset, budget), 0);
        if (count <= 0) {
            if (count == 0 || !RetryableSocketError()) {
                [self abortClient:2 reason:@"client_write"];
            }
            break;
        }
        budget -= (size_t)count;
        _writeOffset += (NSUInteger)count;
        if (write.credited) {
            delivered += (uint32_t)count;
            _deliveredBytes += (uint64_t)count;
        }
        if (_writeOffset == write.bytes.length) {
            [_writes removeObjectAtIndex:0];
            _writeOffset = 0;
        }
    }
    if (_client < 0) {
        return;
    }
    if (delivered && _stage == ClientStreaming) {
        _lastProgress = [_owner now];
        _rxCredit += delivered;
        uint32_t network = htonl(delivered);
        _send(RelayWindowUpdate, _streamID, [NSData dataWithBytes:&network length:sizeof(network)]);
    }
    if (!_writes.count) {
        if (_stage == ClientDraining) {
            [self retire:@"graceful" aborted:NO];
            [self dropClient:@"drained"];
        } else if (_stage == ClientStreaming && _watchEOF && !_clientOutputShutdown) {
            shutdown(_client, SHUT_WR);
            _clientOutputShutdown = YES;
        }
    }
}

- (void)tick {
    if (_client < 0) {
        return;
    }
    if (_stage != ClientStreaming && [_owner now] >= _deadline) {
        if (_stage == ClientOpening) {
            uint32_t streamID = _streamID;
            [self retire:@"open_timeout" aborted:YES];
            [self socksFailure:6];
            _send(RelayClose, streamID, SingleByte(2));
        } else {
            [self dropClient:@"client_timeout"];
        }
        return;
    }
    [self readClient];
    if (_client >= 0) {
        [self flushClient];
    }
    if (_client >= 0 && _stage == ClientStreaming && [_owner now] - _lastProgress >= IdleTimeout) {
        [self abortClient:2 reason:@"idle_timeout"];
    }
}

- (BOOL)receive:(RelayMessage)type payload:(NSData *)payload increment:(uint32_t)increment {
    const uint8_t *bytes = payload.bytes;
    uint32_t streamID = _streamID;
    if (_stage == ClientOpening) {
        if (type == RelayOpenError || (type == RelayClose && bytes[0] != 0)) {
            uint8_t code = type == RelayOpenError ? bytes[0] : 1;
            [self retire:@"remote_open_failed" aborted:YES];
            [self socksFailure:code];
            return YES;
        }
        if (type != RelayOpenOK) {
            return NO;
        }
        const uint8_t header[] = {5, 0, 0};
        NSMutableData *reply = [NSMutableData dataWithBytes:header length:sizeof(header)];
        [reply appendData:payload];
        [self queue:reply credited:NO];
        _txCredit = StreamCredit;
        _rxCredit = StreamCredit;
        _stage = ClientStreaming;
        _lastProgress = [_owner now];
        _log(@"stream_open_ok", @{@"stream": @(streamID)});
        return YES;
    }
    if (_stage == ClientDraining) {
        return type == RelayClose || type == RelayWindowUpdate;
    }
    if (_stage != ClientStreaming) {
        return NO;
    }
    switch (type) {
        case RelayData:
            if (_watchEOF || payload.length > _rxCredit) {
                return NO;
            }
            _rxCredit -= (uint32_t)payload.length;
            _lastProgress = [_owner now];
            [self queue:payload credited:YES];
            return YES;
        case RelayWindowUpdate:
            if (increment > StreamCredit - _txCredit) {
                return NO;
            }
            _txCredit += increment;
            _lastProgress = [_owner now];
            return YES;
        case RelayHalfClose:
            if (_watchEOF) {
                return NO;
            }
            _watchEOF = YES;
            _lastProgress = [_owner now];
            return YES;
        case RelayClose:
            if (bytes[0]) {
                _log(@"stream_remote_abort", @{@"stream": @(streamID), @"reason": @(bytes[0])});
                [self dropClient:@"remote_abort"];
            } else if (_watchEOF && _clientEOF) {
                [self drain];
            } else {
                return NO;
            }
            return YES;
        default:
            return NO;
    }
}
@end

@implementation SocksProxy {
    RelayFrameHandler _send;
    SocksProxyLog _log;
    SocksProxyClock _clock;
    int _listener;
    uint32_t _nextID;
    NSMutableOrderedSet<NSNumber *> *_retiredAborts;
    NSMutableArray<SocksClient *> *_clients;
    NSMutableArray<SocksAdmission *> *_waiting;
    NSUInteger _waitingLimit;
    NSTimeInterval _admissionTimeout;
    NSTimeInterval _burstIdleTimeout;
    NSUInteger _nextTurn;
    NSTimeInterval _lastOverloadLog;
}

- (instancetype)initWithSend:(RelayFrameHandler)send log:(SocksProxyLog)log {
    return [self initWithSend:send log:log wideMode:NO clock:nil];
}

- (instancetype)initWithSend:(RelayFrameHandler)send log:(SocksProxyLog)log
                    wideMode:(BOOL)wideMode clock:(SocksProxyClock)clock {
    self = [super init];
    if (self) {
        _send = [send copy];
        _log = [log copy];
        _clock = clock ? [clock copy] : [^{ return Uptime(); } copy];
        _listener = -1;
        _nextID = 1;
        _retiredAborts = [NSMutableOrderedSet orderedSetWithCapacity:64];
        _streamLimit = wideMode ? WideStreamLimit : BrowserStreamLimit;
        _waitingLimit = wideMode ? WideWaitingLimit : BrowserStreamLimit;
        _admissionTimeout = wideMode ? WideAdmissionTimeout : BrowserAdmissionTimeout;
        _burstIdleTimeout = wideMode ? WideBurstIdleTimeout : PressureIdleTimeout;
        _clients = [NSMutableArray arrayWithCapacity:_streamLimit];
        _waiting = [NSMutableArray arrayWithCapacity:_waitingLimit];
    }
    return self;
}

- (NSTimeInterval)now {
    return _clock();
}

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error {
    _listener = socket(AF_INET, SOCK_STREAM, 0);
    if (_listener >= 0) {
        struct sockaddr_in addr = {
            .sin_len = sizeof(addr),
            .sin_family = AF_INET,
            .sin_port = htons(port),
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        };
        int reuse = 1;
        if (ConfigureSocket(_listener) && setsockopt(_listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) == 0
            && bind(_listener, (const struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(_listener, (int)_waitingLimit) == 0) {
            socklen_t length = sizeof(addr);
            if (getsockname(_listener, (struct sockaddr *)&addr, &length) == 0) {
                _boundPort = ntohs(addr.sin_port);
                _log(@"socks_listening", @{@"port": @(_boundPort), @"max_streams": @(_streamLimit), @"credit_bytes": @(StreamCredit),
                    @"idle_seconds": @(IdleTimeout), @"pressure_idle_seconds": @(PressureIdleTimeout),
                    @"burst_idle_seconds": @(_burstIdleTimeout), @"max_waiting": @(_waitingLimit),
                    @"admission_timeout_seconds": @(_admissionTimeout)});
                return YES;
            }
        }
    }
    int failure = errno;
    [self stop];
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
    }
    return NO;
}

- (void)dealloc {
    if (_listener >= 0) {
        close(_listener);
    }
}

- (void)stop {
    if (_listener >= 0) {
        close(_listener);
        _listener = -1;
    }
    for (SocksClient *client in _clients) {
        [client dropClient:@"link_stopped"];
    }
    [_clients removeAllObjects];
    for (SocksAdmission *pending in _waiting) {
        [pending reject];
    }
    [_waiting removeAllObjects];
}

- (uint32_t)allocateStream {
    return _nextID == UINT32_MAX ? 0 : _nextID++;
}

- (void)retireStream:(uint32_t)streamID aborted:(BOOL)aborted {
    if (aborted) {
        // A long-lived stream can be cancelled after many newer streams.
        // Frames already in flight may still arrive just after cancellation.
        [_retiredAborts addObject:@(streamID)];
        if (_retiredAborts.count > 64) {
            [_retiredAborts removeObjectAtIndex:0];
        }
    }
}

- (BOOL)makeRoomAt:(NSTimeInterval)now {
    if (_clients.count < _streamLimit) {
        return YES;
    }
    // Reclaim idle connections sooner when a full wave is queued behind them.
    NSTimeInterval idleTimeout = _waiting.count >= _streamLimit ? _burstIdleTimeout : PressureIdleTimeout;
    SocksClient *oldest = nil;
    for (SocksClient *client in _clients) {
        if ([client canEvictAt:now idleFor:idleTimeout] && (!oldest || client.lastProgress < oldest.lastProgress)) {
            oldest = client;
        }
    }
    if (!oldest) {
        return NO;
    }
    [oldest evictForCapacity];
    [_clients removeObjectIdenticalTo:oldest];
    return YES;
}

- (void)admitSocket:(int)socket {
    if (_listener < 0) {
        ResetSocket(socket);
        return;
    }
    int noDelay = 1;
    setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay));
    [_clients addObject:[[SocksClient alloc] initWithSocket:socket owner:self send:_send log:_log]];
}

- (void)admitWaiting {
    if (!_waiting.count) {
        return;
    }
    NSTimeInterval now = [self now];
    for (SocksAdmission *pending in [_waiting copy]) {
        BOOL expired = now - pending.queuedAt >= _admissionTimeout;
        if (expired || [pending disconnected]) {
            [pending reject];
            [_waiting removeObjectIdenticalTo:pending];
            _log(expired ? @"socks_admission_expired" : @"socks_admission_cancelled", @{@"waiting": @(_waiting.count)});
        }
    }
    while (_waiting.count && _listener >= 0 && [self makeRoomAt:now]) {
        SocksAdmission *pending = _waiting.firstObject;
        if (!pending) {
            break;
        }
        [_waiting removeObjectAtIndex:0];
        [self admitSocket:[pending takeSocket]];
        _log(@"socks_admission_released", @{@"wait_ms": @((now - pending.queuedAt) * 1000), @"waiting": @(_waiting.count)});
    }
}

- (void)acceptClients {
    for (NSUInteger attempt = 0; attempt < _streamLimit && _listener >= 0; attempt++) {
        int socket = accept(_listener, NULL, NULL);
        if (socket < 0) {
            return;
        }
        if (!ConfigureSocket(socket)) {
            close(socket);
            return;
        }
        NSTimeInterval now = [self now];
        if (!_waiting.count && [self makeRoomAt:now]) {
            [self admitSocket:socket];
        } else if (_waiting.count < _waitingLimit) {
            [_waiting addObject:[[SocksAdmission alloc] initWithSocket:socket queuedAt:now]];
            _log(@"socks_admission_queued", @{@"waiting": @(_waiting.count)});
        } else {
            ResetSocket(socket);
            if (!_lastOverloadLog || now - _lastOverloadLog >= 1) {
                _lastOverloadLog = now;
                _log(@"socks_overload", @{@"max_streams": @(_streamLimit), @"max_waiting": @(_waitingLimit), @"reason": @"queue_full"});
            }
        }
    }
}

- (void)tick {
    if (_listener < 0) {
        return;
    }
    NSArray<SocksClient *> *clients = [_clients copy];
    NSUInteger count = clients.count;
    for (NSUInteger offset = 0; offset < count; offset++) {
        SocksClient *client = clients[(_nextTurn + offset) % count];
        [client tick];
        if (client.closed) {
            [_clients removeObjectIdenticalTo:client];
        }
    }
    _nextTurn = count ? (_nextTurn + 1) % count : 0;
    [self admitWaiting];
    [self acceptClients];
}

- (BOOL)receive:(RelayMessage)type streamID:(uint32_t)streamID payload:(NSData *)payload {
    const uint8_t *bytes = payload.bytes;
    uint32_t increment = 0;
    switch (type) {
        case RelayOpenOK:
            if (!((bytes[0] == 1 && payload.length == 7) || (bytes[0] == 4 && payload.length == 19))) {
                return NO;
            }
            break;
        case RelayOpenError:
            if (bytes[0] < 1 || bytes[0] > 8) {
                return NO;
            }
            break;
        case RelayClose:
            if (bytes[0] > 4) {
                return NO;
            }
            break;
        case RelayWindowUpdate:
            memcpy(&increment, bytes, sizeof(increment));
            increment = ntohl(increment);
            if (!increment || increment > StreamCredit) {
                return NO;
            }
            break;
        case RelayData:
        case RelayHalfClose:
            break;
        default:
            return NO;
    }
    for (SocksClient *client in _clients) {
        if (client.streamID == streamID) {
            return [client receive:type payload:payload increment:increment];
        }
    }
    if (streamID >= _nextID) {
        return NO;
    }
    return type == RelayClose || type == RelayWindowUpdate || [_retiredAborts containsObject:@(streamID)];
}
@end
