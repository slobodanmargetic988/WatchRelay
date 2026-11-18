# WatchRelay protocol v1

The watch is the secure Bluetooth Classic RFCOMM server. The Mac discovers the
`WatchRelay` SDP service with UUID `0c5bc6fa-c662-4fc0-bc94-62a1ce97de9d` and
opens its advertised channel. The watch requires an OS bond and local app
approval before acknowledging the handshake. Both requirements apply to the
probe and echo operations.

RFCOMM is a byte stream. Read each complete header and payload in order.
Serialize writes so frames cannot interleave. All integers are unsigned and
big-endian.

| Offset | Bytes | Field |
| --- | ---: | --- |
| 0 | 1 | Version, always 1 |
| 1 | 1 | Type |
| 2 | 2 | Flags, always 0 |
| 4 | 4 | Stream ID, always 0 in the probe |
| 8 | 4 | Payload length |

| Type | Name | Sender | Payload |
| ---: | --- | --- | --- |
| 1 | `HELLO` | Mac | Empty |
| 2 | `HELLO_ACK` | Watch | Empty |
| 3 | `PING` | Mac | 1–256 opaque bytes |
| 4 | `PONG` | Watch | Exact bytes of the corresponding `PING` |
| 5 | `CELL_PROBE` | Mac | Empty |
| 6 | `CELL_RESULT` | Watch | Status byte `0` for failure or `1` for success, followed by up to 1023 bytes of UTF-8 diagnostics |

Send `HELLO` once per connection and wait for `HELLO_ACK` before sending
`PING` or `CELL_PROBE`. The Mac sends one probe at a time and continues
sending echo challenges while the watch tests cellular HTTPS. Validate type,
flags, stream ID and length before reading the payload. Close a malformed
session. Results and outstanding pings belong to a single connection.

## TCP streams

The relay build keeps the same header, handshake and link-control messages.
Stream messages carry a nonzero stream ID. The Mac assigns increasing IDs
for the lifetime of the Bluetooth link. The current relay build supports eight active or pending TCP streams.

| Type | Name | Sender | Payload |
| ---: | --- | --- | --- |
| 7 | `OPEN` | Mac | SOCKS5 destination address type, address and port |
| 8 | `OPEN_OK` | Watch | SOCKS5 bound address type, numeric address and port |
| 9 | `OPEN_ERR` | Watch | One SOCKS5 failure code from 1 through 8 |
| 10 | `DATA` | Either | 1–16384 application bytes |
| 11 | `HALF_CLOSE` | Either | Empty |
| 12 | `CLOSE` | Either | One reason byte |
| 13 | `WINDOW_UPDATE` | Either | Positive 32-bit credit from 1 through 65536 |

Address encodings follow [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928).
The watch resolves hostnames using its cellular network, binds the socket to
that network and returns `OPEN_OK` after TCP connect succeeds. Each direction
starts with 65536 bytes of credit at `OPEN_OK`. A sender deducts each DATA
payload size and waits for credit before sending more. A recipient returns
credit only for bytes written to its local TCP socket. Credit cannot exceed
65536 bytes in either direction. Eight streams therefore have 512 KiB of
application credit per direction across the link. Both writers bound their
queues and schedule streams in rotation. Link controls and stream frames
remain separate, and stream EOF stays behind that stream's queued data.

A receiver drains earlier DATA before acting on `HALF_CLOSE` by shutting down
only its TCP output. The watch sends graceful `CLOSE` once both directions
reach EOF and its queued data drains. The Mac drains any remaining queued
data when it receives graceful CLOSE. Abortive CLOSE discards pending data.
The reason byte is 0 for graceful, 1 for I/O error, 2 for cancellation,
3 for a protocol error or 4 for cellular loss. Valid late CLOSE and
WINDOW_UPDATE frames for retired streams can be ignored.

The Mac listens on IPv4 loopback. It accepts SOCKS5 TCP CONNECT with the
no-authentication method. It sends SOCKS success after OPEN_OK, and returns
OPEN_ERR as a SOCKS failure. Applications must send hostnames to get
watch-side DNS. TLS passes through end to end. Closing the Bluetooth link
terminates its streams. A new session carries only new requests.


## Automatic connection

In automatic mode the Mac publishes a transient Classic Bluetooth RFCOMM
service under the same WatchRelay UUID. The watch initiates a secure socket
to the selected bonded Mac and retries while the session is active. The Mac
keeps its service registered across dropped links and accepts only the
selected bonded watch.

Enrollment happens over the previously approved secure forward link after
HELLO_ACK. The Mac sends stream-zero AUTO_ENROLL (14) with 32 random key
bytes. The watch saves the key privately for the approved peer and returns
empty AUTO_ENROLLED (15). Neither app logs the key.

On enrolled incoming links, the Mac sends stream-zero AUTO_CHALLENGE (16)
with a fresh 32-byte nonce. The watch replies with AUTO_PROOF (17), its own
32-byte nonce followed by HMAC-SHA256 over the ASCII tag
`WatchRelay auto watch v1` and the two nonces in Mac, watch order. The Mac
checks the proof and replies with AUTO_ACCEPT (18), the corresponding HMAC
under the ASCII tag `WatchRelay auto mac v1`. The watch verifies that reply.
Normal HELLO and HELLO_ACK follow mutual proof. The Mac only opens SOCKS
after these checks succeed.
