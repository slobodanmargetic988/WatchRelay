# WatchRelay test report

These measurements describe a personal hardware experiment performed on
10 November 2026. The project is a prototype for light backup internet.
**Overall relay downloads measured roughly 0.2 Mbps**, with the bulk slowdown
located on the Bluetooth relay path. Results apply to the tested hardware,
firmware, carrier, workload, and build.

## Tested setup

| Component | Observation |
| --- | --- |
| Mac | Apple silicon, arm64, macOS 27.2 |
| Bluetooth adapter | Enabled BCM_4378 controller |
| Watch | Galaxy Watch5 LTE 40 mm, model SM-R905F |
| Watch platform | Android 16, API 36, Wear OS 6, One UI Watch 8 |
| Current watch build | 0.1.6-relay, version code 7 |
| Current Mac helper | 0.1.9-relay |
| Tunnel engine | Pinned sing-box 1.14.4 for Apple silicon |
| Cellular egress | Usable IPv4. Literal IPv6 attempts returned network-unreachable errors. |

The watch app requested a cellular network explicitly and logged the selected
transport for outbound connections. Direct and relay HTTPS requests kept normal
certificate validation enabled. The watch's existing phone pairing was retained.
Raw device logs, addresses, pairing information, and build artifacts are local
and excluded from the public repository. This report preserves the aggregate
results without publishing those identifiers.

## What passed

| Check | Result |
| --- | --- |
| Physical installation | The native watch APK installed and launched on the Watch5. Mac helper signatures and diagnostics were checked. |
| Independent upstream | Watch Wi-Fi and phone Bluetooth were off during the isolated cellular probe. The HTTPS request returned HTTP 200 in 1.108 s while Bluetooth echoes continued. |
| Simultaneous Bluetooth and LTE | Eight echo payloads matched. Median echo RTT was 54.8 ms, with a 33.4–432.2 ms range. |
| Mac offline relay | With Mac Wi-Fi off, a direct request failed and the same URL through WatchRelay returned HTTP 200 and 577 bytes in 4.906 s. |
| Stop without direct fallback | Stopping the watch session closed the local proxy. The forced request failed while the Mac's separate direct connection still worked. |
| Browser mode | The user reloaded a page in the visible temporary Chrome profile with Mac Wi-Fi off. An automated Chrome request also passed. |
| Concurrency and cancellation | Four HTTPS requests completed in 7.63–8.09 s while a fifth TLS client stopped reading. A fresh request passed after canceling the slow client. |
| Automatic discovery | The watch rediscovered and authenticated the Mac after the helper restarted on a different RFCOMM channel, without another watch tap or channel entry. |
| Screen-off operation | Successful traffic overlapped noninteractive watch samples with no app wake lock or keep-awake workaround. |
| Mac-wide route | A timed standalone tunnel started with Mac Wi-Fi off. macOS reported it online, fresh system DNS worked, and both ordinary HTTPS checks passed. |
| Ordinary applications | Normal Chrome browsing passed. The user sent a message in the existing Claude Desktop app and received a reply during the successful Wi-Fi-off trial. |
| Codex | Two-way TCP application traffic was observed on the tunnel. A completed request in the app remains unverified. |
| Restoration | After Wi-Fi reconnected and the tunnel stopped, the route and resolver matched the baseline. Ordinary DNS and HTTPS passed again. |

## Throughput and integrity

A 256 KiB HTTPS download through the SOCKS relay completed in 10.53 seconds,
about 0.20 Mbit/s including connection setup. First byte arrived after 3.31
seconds. This path includes the relay and watch LTE, without the Mac-wide tunnel.

The same 256 KiB HTTPS response was then requested directly on the watch and
through the Mac relay. Both returned HTTP 200 and matching SHA-256 values.
Watch Wi-Fi was available for debugging, while the direct benchmark explicitly
selected cellular. A third test used a server on the watch itself, removing
cellular from the payload path.

| Path | Time to first byte | Body transfer | Total |
| --- | ---: | ---: | ---: |
| Watch direct LTE | 2.29 s | 0.21 s | 2.50 s |
| Mac → Bluetooth relay → watch LTE | 2.60 s | 7.52 s | 10.13 s |
| Mac → Bluetooth relay → watch-local server | 2.06 s | 8.58 s | 10.64 s |

The short direct sample transferred the body at about 9.9 Mbit/s. The matched
relay body transferred at about 0.28 Mbit/s, near the watch-local test's
0.24 Mbit/s. This locates the slowdown on the WatchRelay link and software path.
The experiment does not separate Bluetooth radio limits from relay overhead.

An output-buffer experiment produced watch-local body measurements of 0.24 and
0.33 Mbit/s. The restored build measured 0.26 and 0.31 Mbit/s immediately
afterward. There was no consistent gain, so the installed APK was restored.
The temporary LTE diagnostic app was removed after testing.

Earlier integrity checks also passed a 1 MiB download with a matching SHA-256 in
59.945 s, about 0.140 Mbit/s including setup, and a 256 KiB synthetic upload in
13.439 s, about 0.156 Mbit/s. These were separate runs with different background
traffic and should not be interpreted as a fixed capacity.

## Battery and thermal observations

A 15-minute light-use run on watch build 0.1.4-relay and Mac helper 0.1.5-relay
completed all 15 scheduled requests in 900.008 seconds. It requested 884,736
bytes, using 8 KiB each minute and 256 KiB on every fifth minute. A separate
integrity download and upload also ran near the beginning.

The unplugged watch dropped from 41% to 24%, a 17-percentage-point change. It
was noninteractive in 30 of 32 samples. The maximum reported Android thermal
status was 0, and no Bluetooth interruption or thermal stop was logged.
Mac and watch Wi-Fi remained available for management, while outbound sockets
were logged on cellular. The earlier route-isolation tests were separate.

This is one workload measurement. It does not establish all-day availability,
a guaranteed battery duration, surface temperature, or off-wrist behavior.

## Mac-wide implementation findings

The publisher-signed SFM Network Extension passed default-route and system DNS
checks with Mac Wi-Fi on. On the tested Mac, macOS refused to start that VPN
with all ordinary networks off. Its stop operation restored routing and DNS.

The default standalone engine was added to start from the offline state. Its
session owns temporary routes, DNS, and a macOS online-service record. A timed
trial rolls the session back independently of the chat or Terminal. The
successful Mac-wide test used helper 0.1.9-relay and watch 0.1.5-relay, before
the watch launcher-icon update to 0.1.6-relay.

The profile captures the default IPv4 and IPv6 internet routes, answers system
DNS through TLS-verified Cloudflare DNS over HTTPS through the watch, and
rejects IPv6 and non-DNS UDP. Existing local routes and system exceptions remain
outside that default-route claim. The local tunnel adds no hosted service.

Early Mac-wide attempts exposed capacity problems as background applications
reconnected. The helper grew from eight streams to 24 active streams and a
bounded 96-connection waiting queue, with a 12-second waiting deadline and idle
cleanup under pressure. A later Wi-Fi-off trial passed fresh DNS and both HTTPS
checks on its first attempt, followed by the completed Claude Desktop request.

## Fixes exercised during testing

- macOS returned a stale watch service channel after the watch session restarted.
  Automatic mode now lets the watch discover the Mac's service by UUID.
- A heartbeat timeout interrupted a large download despite active traffic. The
  liveness check now accepts valid inbound frames as evidence of a live link.
- Idle browser connections exhausted the initial stream limit. Idle cleanup,
  fair scheduling, and bounded admission queues were added and tested.
- Late frames from a canceled stream could terminate a newer link. A regression
  test verifies isolation of retired streams.
- The first restoration check ran before Wi-Fi regained its normal route. The
  offline test now waits for Wi-Fi connectivity before removing the trial tunnel.

## Software validation

Android lint, APK signature verification, and 17 watch unit tests passed for
the current watch build. Tests cover malformed and fragmented frames, unsigned
stream IDs, destination parsing, authentication, queue bounds, credit accounting,
and stream ordering. Mac tests cover frame parsing, SOCKS negotiation,
flow control, half-close, multi-stream isolation, idle eviction, bounded
admission, authentication role separation, and link cleanup. Tunnel staging
verifies the pinned engine and validates its configuration before use.

Compilation and software checks support the implementation. The physical
outcomes above establish the device-specific claims.

## Remaining limits

Off-wrist locking, disabling and restoring cellular during active transfers,
physical range-loss recovery, corporate VPN coexistence, and extended battery
runs remain unverified. A completed Codex request needs a separate app test.
UDP-only and IPv6-only applications need additional support. Large downloads,
video, and heavy background activity can be slow or reach the queue limits.

The public repository contains source and these summarized results. Local raw
logs and installation artifacts are intentionally excluded. Follow the
[Mac-wide guide](mac-wide.md) for switching off, restoring, and removing the
optional SFM setup.
