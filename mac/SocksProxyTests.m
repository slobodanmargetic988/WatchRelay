#import "SocksProxy.h"

#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

static void Check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSData *Data(const uint8_t *bytes, size_t length) {
    return [NSData dataWithBytes:bytes length:length];
}

static int ConnectLocal(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    Check(fd >= 0, "local socket");
    int one = 1;
    Check(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) == 0, "disable test Nagle delay");
    struct timeval timeout = {.tv_sec = 2};
    Check(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0, "test deadline");
    struct sockaddr_in address = {
        .sin_len = sizeof(address),
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    Check(connect(fd, (const struct sockaddr *)&address, sizeof(address)) == 0, "connect to loopback");
    return fd;
}

static void Write(int fd, const uint8_t *data, size_t size) {
    Check(write(fd, data, size) == (ssize_t)size, "write request");
}

static void Expect(SocksProxy *proxy, int fd, const uint8_t *expected, size_t size) {
    uint8_t data[64];
    Check(size <= sizeof(data), "expect bounded bytes");
    size_t total = 0;
    for (int attempt = 0; total < size && attempt < 200; attempt++) {
        [proxy tick];
        ssize_t count = recv(fd, data + total, size - total, MSG_DONTWAIT);
        if (count > 0) {
            total += (size_t)count;
        } else if (count == 0 || (errno != EAGAIN && errno != EINTR)) {
            break;
        }
        usleep(1000);
    }
    Check(total == size && !memcmp(data, expected, size), "receive expected bytes");
}

static void WaitForFrames(SocksProxy *proxy, NSArray *frames, NSUInteger count) {
    for (int attempt = 0; frames.count < count && attempt < 200; attempt++) {
        [proxy tick];
        usleep(1000);
    }
    Check(frames.count == count, "expected number of relay frames");
}

static void CheckConcurrentClients(SocksProxy *proxy, NSMutableArray *frames) {
    [frames removeAllObjects];
    int clients[4];
    const uint8_t greeting[] = {5, 1, 0};
    const uint8_t methodOK[] = {5, 0};
    const uint8_t bound[] = {1, 192, 0, 2, 1, 0xbe, 0xef};
    const uint8_t reply[] = {5, 0, 0, 1, 192, 0, 2, 1, 0xbe, 0xef};
    for (NSUInteger index = 0; index < 4; index++) {
        clients[index] = ConnectLocal(proxy.boundPort);
        Write(clients[index], greeting, sizeof(greeting));
    }
    for (NSUInteger index = 0; index < 4; index++) {
        Expect(proxy, clients[index], methodOK, sizeof(methodOK));
        const uint8_t request[] = {5, 1, 0, 3, 1, (uint8_t)('a' + index), 1, 0xbb};
        Write(clients[index], request, sizeof(request));
    }
    WaitForFrames(proxy, frames, 4);
    uint32_t streamIDs[4] = {0};
    for (NSArray *frame in frames) {
        NSData *payload = frame[2];
        const uint8_t *bytes = payload.bytes;
        Check([frame[0] intValue] == RelayOpen && payload.length == 5 && bytes[0] == 3
            && bytes[2] >= 'a' && bytes[2] <= 'd', "match each OPEN to its socket");
        NSUInteger index = bytes[2] - 'a';
        Check(!streamIDs[index], "each socket gets its own OPEN");
        streamIDs[index] = [frame[1] unsignedIntValue];
        Check([proxy receive:RelayOpenOK streamID:streamIDs[index] payload:Data(bound, sizeof(bound))],
            "four simultaneous OPEN_OK replies accepted");
    }
    for (NSUInteger index = 0; index < 4; index++) {
        Expect(proxy, clients[index], reply, sizeof(reply));
    }
    const uint8_t bulk[16384] = {0};
    for (NSUInteger index = 0; index < 4; index++) {
        Check([proxy receive:RelayData streamID:streamIDs[0] payload:Data(bulk, sizeof(bulk))],
            "one client can queue its full credit");
    }
    Check(![proxy receive:RelayData streamID:streamIDs[0] payload:Data(bulk, 1)], "queued data cannot exceed stream credit");
    for (NSUInteger index = 1; index < 4; index++) {
        const uint8_t result[] = {(uint8_t)index, 0xf0};
        Check([proxy receive:RelayData streamID:streamIDs[index] payload:Data(result, sizeof(result))],
            "other streams accept data while one client is paused");
    }
    for (NSUInteger index = 1; index < 4; index++) {
        const uint8_t result[] = {(uint8_t)index, 0xf0};
        Expect(proxy, clients[index], result, sizeof(result));
    }
    [proxy stop];
    for (NSUInteger index = 0; index < 4; index++) {
        uint8_t value;
        ssize_t count;
        do {
            count = recv(clients[index], &value, 1, 0);
        } while (count > 0);
        Check(count == 0 || errno == ECONNRESET, "link stop closes every client");
        close(clients[index]);
    }
}

static uint32_t FinishLocalConnect(SocksProxy *proxy, NSMutableArray *frames, int fd, BOOL greeted) {
    const uint8_t greeting[] = {5, 1, 0};
    const uint8_t methodOK[] = {5, 0};
    const uint8_t request[] = {5, 1, 0, 1, 192, 0, 2, 2, 0x01, 0xbb};
    const uint8_t bound[] = {1, 192, 0, 2, 1, 0xbe, 0xef};
    const uint8_t reply[] = {5, 0, 0, 1, 192, 0, 2, 1, 0xbe, 0xef};
    if (!greeted) {
        Write(fd, greeting, sizeof(greeting));
    }
    Expect(proxy, fd, methodOK, sizeof(methodOK));
    NSUInteger expected = frames.count + 1;
    Write(fd, request, sizeof(request));
    WaitForFrames(proxy, frames, expected);
    NSArray *frame = frames.lastObject;
    Check([frame[0] intValue] == RelayOpen, "newly admitted connection opens upstream");
    uint32_t streamID = [frame[1] unsignedIntValue];
    uint8_t scratch;
    Check(recv(fd, &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "admitted client waits for upstream success");
    Check([proxy receive:RelayOpenOK streamID:streamID payload:Data(bound, sizeof(bound))], "watch accepted admitted stream");
    Expect(proxy, fd, reply, sizeof(reply));
    return streamID;
}

static void ExpectClosed(SocksProxy *proxy, int fd) {
    uint8_t byte;
    for (int attempt = 0; attempt < 200; attempt++) {
        [proxy tick];
        ssize_t count = recv(fd, &byte, sizeof(byte), MSG_DONTWAIT);
        if (count == 0 || (count < 0 && errno == ECONNRESET)) {
            return;
        }
        Check(count < 0 && (errno == EAGAIN || errno == EINTR), "client is closed or briefly waiting");
        usleep(1000);
    }
    Check(NO, "client failed promptly");
}

static void CheckIdleAdmission(void) {
    __block NSTimeInterval now = 100;
    NSMutableArray *frames = [NSMutableArray array];
    NSMutableArray *events = [NSMutableArray array];
    SocksProxy *proxy = [[SocksProxy alloc] initWithSend:^(RelayMessage type, uint32_t streamID, NSData *payload) {
        [frames addObject:@[@(type), @(streamID), payload]];
    } log:^(NSString *event, NSDictionary *fields) {
        [events addObject:@[event, fields]];
    } wideMode:NO clock:^{ return now; }];
    Check([proxy startOnPort:0 error:nil], "start capacity test listener");
    int clients[8];
    uint32_t ids[8];
    for (NSUInteger index = 0; index < 8; index++) {
        clients[index] = ConnectLocal(proxy.boundPort);
        ids[index] = FinishLocalConnect(proxy, frames, clients[index], NO);
    }

    now = 101;
    int waiting[8];
    for (NSUInteger index = 0; index < 8; index++) {
        waiting[index] = ConnectLocal(proxy.boundPort);
        [proxy tick];
    }
    int blocked = ConnectLocal(proxy.boundPort);
    ExpectClosed(proxy, blocked);
    Check(frames.count == 8 && [events.lastObject[0] isEqual:@"socks_overload"]
        && [events.lastObject[1][@"reason"] isEqual:@"queue_full"], "eight waiting clients are bounded and overflow fails promptly");
    close(blocked);

    close(waiting[7]);
    for (int attempt = 0; attempt < 200 && ![events.lastObject[0] isEqual:@"socks_admission_cancelled"]; attempt++) {
        [proxy tick];
        usleep(1000);
    }
    Check([events.lastObject[0] isEqual:@"socks_admission_cancelled"], "abandoned queued client releases its waiting slot");
    waiting[7] = ConnectLocal(proxy.boundPort);
    [proxy tick];
    Check([events.lastObject[0] isEqual:@"socks_admission_queued"], "replacement uses the released waiting slot");

    now = 109;
    for (NSUInteger index = 0; index < 8; index++) {
        ExpectClosed(proxy, waiting[index]);
        close(waiting[index]);
    }
    Check(frames.count == 8 && [events.lastObject[0] isEqual:@"socks_admission_expired"], "expired clients never open an upstream stream");

    now = 110;
    int burstFirst = ConnectLocal(proxy.boundPort);
    int burstSecond = ConnectLocal(proxy.boundPort);
    const uint8_t greeting[] = {5, 1, 0};
    Write(burstFirst, greeting, sizeof(greeting));
    Write(burstSecond, greeting, sizeof(greeting));
    [proxy tick];
    uint8_t scratch;
    Check(recv(burstFirst, &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "queued SOCKS greeting waits for an active slot");
    const uint8_t remoteAbort[] = {1};
    Check([proxy receive:RelayClose streamID:ids[7] payload:Data(remoteAbort, sizeof(remoteAbort))], "first active slot released");
    uint32_t burstFirstID = FinishLocalConnect(proxy, frames, burstFirst, YES);
    Check(recv(burstSecond, &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "newer queued client waits its turn");
    Check([proxy receive:RelayClose streamID:ids[6] payload:Data(remoteAbort, sizeof(remoteAbort))], "second active slot released");
    uint32_t burstSecondID = FinishLocalConnect(proxy, frames, burstSecond, YES);
    Check(burstSecondID > burstFirstID && frames.count == 10, "cold-start burst opens in arrival order");

    now = 116;
    [proxy tick];
    Check(frames.count == 10, "15-second pressure deadline alone does not close streams");
    Check(shutdown(clients[0], SHUT_WR) == 0, "half-close before capacity pressure");
    WaitForFrames(proxy, frames, 11);
    Check([frames.lastObject isEqual:@[@(RelayHalfClose), @(ids[0]), NSData.data]], "half-close retained during capacity pressure");

    const uint8_t data[] = {0xab};
    Write(clients[2], data, sizeof(data));
    WaitForFrames(proxy, frames, 12);
    Check([frames.lastObject isEqual:@[@(RelayData), @(ids[2]), Data(data, sizeof(data))]], "active third stream sent bytes");

    int admitted = ConnectLocal(proxy.boundPort);
    WaitForFrames(proxy, frames, 13);
    const uint8_t cancelled[] = {2};
    Check([frames.lastObject isEqual:@[@(RelayClose), @(ids[1]), Data(cancelled, sizeof(cancelled))]],
        "waiting client evicts oldest fully idle stream only");
    ExpectClosed(proxy, clients[1]);
    uint32_t newID = FinishLocalConnect(proxy, frames, admitted, NO);
    Check(newID > burstSecondID, "evicted capacity opens a distinct stream");
    Check([proxy receive:RelayData streamID:ids[0] payload:Data(data, sizeof(data))], "half-closed stream can still receive data");
    Expect(proxy, clients[0], data, sizeof(data));

    now = 176;
    [proxy tick];
    ExpectClosed(proxy, clients[3]);
    BOOL timedOut = NO;
    for (NSArray *event in events) {
        if ([event[0] isEqual:@"stream_finished"] && [event[1][@"stream"] unsignedIntValue] == ids[3]) {
            timedOut = [event[1][@"code"] isEqual:@"idle_timeout"];
        }
    }
    Check(timedOut, "normal idle deadline closes a 76-second stale stream");
    Check([proxy receive:RelayData streamID:ids[2] payload:Data(data, sizeof(data))], "recent application progress extends idle deadline");
    Expect(proxy, clients[2], data, sizeof(data));
    Check([proxy receive:RelayData streamID:newID payload:Data(data, sizeof(data))], "new client survives old-stream cleanup");
    Expect(proxy, admitted, data, sizeof(data));
    Check([proxy receive:RelayData streamID:burstFirstID payload:Data(data, sizeof(data))], "first queued stream still works");
    Expect(proxy, burstFirst, data, sizeof(data));
    Check([proxy receive:RelayData streamID:burstSecondID payload:Data(data, sizeof(data))], "second queued stream still works");
    Expect(proxy, burstSecond, data, sizeof(data));

    int fill[3];
    for (NSUInteger index = 0; index < 3; index++) {
        fill[index] = ConnectLocal(proxy.boundPort);
        FinishLocalConnect(proxy, frames, fill[index], NO);
    }
    int onStop = ConnectLocal(proxy.boundPort);
    for (int attempt = 0; attempt < 200 && ![events.lastObject[0] isEqual:@"socks_admission_queued"]; attempt++) {
        [proxy tick];
        usleep(1000);
    }
    Check([events.lastObject[0] isEqual:@"socks_admission_queued"], "queued client exists before link stop");
    [proxy stop];
    ExpectClosed(proxy, onStop);
    close(onStop);
    for (NSUInteger index = 0; index < 3; index++) {
        close(fill[index]);
    }
    for (NSUInteger index = 0; index < 8; index++) {
        close(clients[index]);
    }
    close(admitted);
    close(burstFirst);
    close(burstSecond);
}

static void CheckWideAdmission(void) {
    enum { ExpectedLimit = 24, ExpectedWaiting = 96 };
    __block NSTimeInterval now = 100;
    NSMutableArray *frames = [NSMutableArray array];
    NSMutableArray *events = [NSMutableArray array];
    SocksProxy *proxy = [[SocksProxy alloc] initWithSend:^(RelayMessage type, uint32_t streamID, NSData *payload) {
        [frames addObject:@[@(type), @(streamID), payload]];
    } log:^(NSString *event, NSDictionary *fields) {
        [events addObject:@[event, fields]];
    } wideMode:YES clock:^{ return now; }];
    Check([proxy startOnPort:0 error:nil], "start wide-mode listener");
    Check(proxy.streamLimit == ExpectedLimit && [events.lastObject[1][@"max_waiting"] intValue] == ExpectedWaiting
        && [events.lastObject[1][@"credit_bytes"] intValue] == 65536, "wide mode absorbs a larger burst without raising the wire limit");

    int clients[ExpectedLimit];
    uint32_t ids[ExpectedLimit];
    int waiting[ExpectedWaiting];
    for (NSUInteger index = 0; index < ExpectedLimit; index++) {
        clients[index] = ConnectLocal(proxy.boundPort);
        ids[index] = FinishLocalConnect(proxy, frames, clients[index], NO);
    }
    now = 101;
    for (NSUInteger index = 0; index < ExpectedWaiting; index++) {
        waiting[index] = ConnectLocal(proxy.boundPort);
        [proxy tick];
    }
    const uint8_t greeting[] = {5, 1, 0};
    Write(waiting[0], greeting, sizeof(greeting));
    int overflow = ConnectLocal(proxy.boundPort);
    ExpectClosed(proxy, overflow);
    Check(frames.count == ExpectedLimit && [events.lastObject[0] isEqual:@"socks_overload"], "wide-mode queue is bounded");
    close(overflow);

    const uint8_t data[] = {0xab};
    Write(clients[0], data, sizeof(data));
    WaitForFrames(proxy, frames, ExpectedLimit + 1);
    now = 105;
    for (NSUInteger index = 2; index < ExpectedLimit; index++) {
        Write(clients[index], data, sizeof(data));
    }
    WaitForFrames(proxy, frames, ExpectedLimit * 2 - 1);
    uint8_t scratch;
    Check(recv(waiting[0], &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN,
        "wide burst preserves the idle grace period");
    now = 106;
    WaitForFrames(proxy, frames, ExpectedLimit * 2);
    const uint8_t cancelled[] = {2};
    Check([frames.lastObject isEqual:@[@(RelayClose), @(ids[1]), Data(cancelled, sizeof(cancelled))]],
        "wide burst reclaims an idle stream after six seconds and protects older outstanding data");
    ExpectClosed(proxy, clients[1]);
    FinishLocalConnect(proxy, frames, waiting[0], YES);
    Write(waiting[0], data, sizeof(data));
    WaitForFrames(proxy, frames, ExpectedLimit * 2 + 2);

    now = 112;
    [proxy tick];
    Check(recv(waiting[1], &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN,
        "wide admission remains queued past the browser timeout");
    now = 113;
    for (NSUInteger index = 1; index < ExpectedWaiting; index++) {
        ExpectClosed(proxy, waiting[index]);
        close(waiting[index]);
    }
    Check(frames.count == ExpectedLimit * 2 + 2 && [events.lastObject[0] isEqual:@"socks_admission_expired"],
        "wide admission expires at twelve seconds without displacing streams with outstanding data");
    [proxy stop];
    close(waiting[0]);
    for (NSUInteger index = 0; index < ExpectedLimit; index++) {
        close(clients[index]);
    }
}

static void CheckLateDataAfterOldStreamAbort(void) {
    __block NSTimeInterval now = 100;
    NSMutableArray *frames = [NSMutableArray array];
    SocksProxy *proxy = [[SocksProxy alloc] initWithSend:^(RelayMessage type, uint32_t streamID, NSData *payload) {
        [frames addObject:@[@(type), @(streamID), payload]];
    } log:^(NSString *event, NSDictionary *fields) {
        (void)event;
        (void)fields;
    } wideMode:YES clock:^{ return now; }];
    Check([proxy startOnPort:0 error:nil], "start late-frame test listener");
    int old = ConnectLocal(proxy.boundPort);
    uint32_t oldID = FinishLocalConnect(proxy, frames, old, NO);

    // Keep this stream open while more than 64 newer streams are retired.
    const uint8_t remoteAbort[] = {1};
    uint32_t latestID = oldID;
    for (NSUInteger index = 0; index < 65; index++) {
        int newer = ConnectLocal(proxy.boundPort);
        latestID = FinishLocalConnect(proxy, frames, newer, NO);
        Check([proxy receive:RelayClose streamID:latestID payload:Data(remoteAbort, sizeof(remoteAbort))],
            "watch can abort each newer stream");
        close(newer);
    }

    now += 76;
    ExpectClosed(proxy, old);
    const uint8_t localAbort[] = {2};
    Check([frames.lastObject isEqual:@[@(RelayClose), @(oldID), Data(localAbort, sizeof(localAbort))]],
        "the old stream is cancelled after expiring");
    const uint8_t lateData[] = {0x12, 0x34};
    Check([proxy receive:RelayData streamID:oldID payload:Data(lateData, sizeof(lateData))],
        "late data for the newly aborted old stream leaves the link intact");
    Check([proxy receive:RelayHalfClose streamID:oldID payload:NSData.data],
        "late EOF for the newly aborted old stream leaves the link intact");
    Check(![proxy receive:RelayData streamID:oldID + 1 payload:Data(lateData, sizeof(lateData))],
        "an old cancellation eventually ages out of the bounded history");
    Check(![proxy receive:RelayData streamID:latestID + 1 payload:Data(lateData, sizeof(lateData))],
        "data for an unopened stream is still rejected");
    [proxy stop];
    close(old);
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *frames = [NSMutableArray array];
        SocksProxy *proxy = [[SocksProxy alloc] initWithSend:^(RelayMessage type, uint32_t streamID, NSData *payload) {
            [frames addObject:@[@(type), @(streamID), payload]];
        } log:^(NSString *event, NSDictionary *fields) {
            (void)event;
            (void)fields;
        }];
        Check([proxy startOnPort:0 error:nil], "start test listener");
        SocksProxy *conflict = [[SocksProxy alloc] initWithSend:^(RelayMessage t, uint32_t s, NSData *p) {
            (void)t; (void)s; (void)p;
        } log:^(NSString *event, NSDictionary *fields) { (void)event; (void)fields; }];
        NSError *error = nil;
        Check(![conflict startOnPort:proxy.boundPort error:&error] && error.code == EADDRINUSE, "bind conflict reported");
        int fd = ConnectLocal(proxy.boundPort);
        const uint8_t first[] = {5};
        const uint8_t methods[] = {1, 0};
        const uint8_t methodOK[] = {5, 0};
        Write(fd, first, sizeof(first));
        [proxy tick];
        Check(frames.count == 0, "fragmented greeting waits for more bytes");
        Write(fd, methods, sizeof(methods));
        [proxy tick];
        Expect(proxy, fd, methodOK, sizeof(methodOK));

        const uint8_t request[] = {5, 1, 0, 3, 3, 'd', 'n', 's', 0x01, 0xbb, 0x61, 0x62};
        Write(fd, request, sizeof(request));
        Check(shutdown(fd, SHUT_WR) == 0, "early local FIN");
        WaitForFrames(proxy, frames, 1);
        Check(frames.count == 1 && [frames[0] isEqual:@[@(RelayOpen), @1, Data(request + 3, 7)]], "OPEN preserves hostname");
        uint8_t scratch;
        Check(recv(fd, &scratch, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "no SOCKS success before OPEN_OK");

        const uint8_t bound[] = {1, 192, 0, 2, 1, 0xbe, 0xef};
        Check([proxy receive:RelayOpenOK streamID:1 payload:Data(bound, sizeof(bound))], "watch accepted OPEN");
        WaitForFrames(proxy, frames, 3);
        const uint8_t reply[] = {5, 0, 0, 1, 192, 0, 2, 1, 0xbe, 0xef};
        Expect(proxy, fd, reply, sizeof(reply));
        Check(frames.count == 3 && [frames[1] isEqual:@[@(RelayData), @1, Data(request + 10, 2)]]
            && [frames[2] isEqual:@[@(RelayHalfClose), @1, NSData.data]], "initial data precedes client EOF");

        const uint8_t reversed[] = {0xde, 0xad, 0xbe, 0xef};
        Check([proxy receive:RelayData streamID:1 payload:Data(reversed, sizeof(reversed))], "watch data accepted");
        [proxy tick];
        Expect(proxy, fd, reversed, sizeof(reversed));
        WaitForFrames(proxy, frames, 4);
        const uint8_t grant[] = {0, 0, 0, 4};
        Check(frames.count == 4 && [frames[3] isEqual:@[@(RelayWindowUpdate), @1, Data(grant, sizeof(grant))]], "return credit after TCP write");
        Check(![proxy receive:RelayWindowUpdate streamID:1 payload:Data(grant, sizeof(grant))], "reject credit overflow");

        Check([proxy receive:RelayHalfClose streamID:1 payload:NSData.data], "watch EOF accepted");
        const uint8_t graceful[] = {0};
        Check([proxy receive:RelayClose streamID:1 payload:Data(graceful, sizeof(graceful))], "watch completed stream");
        [proxy tick];
        Check(recv(fd, &scratch, 1, 0) == 0, "local EOF after reverse bytes");
        close(fd);

        fd = ConnectLocal(proxy.boundPort);
        const uint8_t greeting[] = {5, 1, 0};
        Write(fd, greeting, sizeof(greeting));
        [proxy tick];
        Expect(proxy, fd, methodOK, sizeof(methodOK));
        const uint8_t unsupported[] = {5, 3, 0, 1, 127, 0, 0, 1, 0x04, 0x38};
        Write(fd, unsupported, sizeof(unsupported));
        [proxy tick];
        const uint8_t refused[] = {5, 7, 0, 1, 0, 0, 0, 0, 0, 0};
        Expect(proxy, fd, refused, sizeof(refused));
        Check(frames.count == 4, "unsupported UDP never opens an upstream stream");
        close(fd);
        CheckConcurrentClients(proxy, frames);
        CheckIdleAdmission();
        CheckWideAdmission();
        CheckLateDataAfterOldStreamAbort();
        puts("PASS: loopback SOCKS negotiation, remote DNS, credit, half-close, concurrency, idle eviction, bounded admission and late-frame cleanup");
    }
    return 0;
}
