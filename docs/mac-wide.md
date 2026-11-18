# Mac-wide Watch Internet

This mode lets existing TCP applications use the watch through the Mac's default
internet route. Normal Chrome browsing and a complete Claude Desktop request
passed with Mac Wi-Fi off. Codex transport was observed, while a completed Codex
request still needs verification.

**Expect roughly 0.2 Mbps from the current relay.** Small pages and messages can
work, but the measured speed and battery cost make this a prototype for light
backup use. The [test report](test-report.md) compares direct watch LTE with the
Bluetooth relay and records the exact limits.

## One-time setup

Use an Apple silicon Mac. First build WatchRelay, install the watch APK, pair the
watch with the Mac, and complete [automatic enrollment](../README.md#enroll-automatic-connection).
Mac-wide mode requires watch build 0.1.5-relay or later and Mac helper
0.1.9-relay or later. The tested current watch build is 0.1.6-relay.

From the repository folder, stage the pinned engine and build the local DNS
helper.

```sh
./mac/wide/stage cli
./mac/wide/build-dns-owner.sh
```

Staging downloads sing-box 1.14.4 for Apple silicon and verifies its pinned
SHA-256. The source profile is `mac/wide/WatchRelay.json`. The generated
standalone profile and binaries stay under the ignored build directory.
Everything runs locally on the Mac and watch, with no server deployment or
ongoing hosting requirement.

## Switch on

1. Keep Bluetooth enabled on both devices and start **Auto-connect** in WatchRelay
   on the watch. The watch needs working mobile data.
2. Double-click **Watch Internet.command** in Finder.
3. Enter your Mac administrator password locally when Terminal requests it.
   The launcher starts the relay, checks cellular HTTPS, creates the temporary
   tunnel, and checks the Mac's route, resolver, and online status.
4. Use your existing apps. Refresh an old connection if needed.

The default standalone engine can start when Mac Wi-Fi is already off. The
watch's cellular sockets remain explicitly bound to its mobile network even
when watch Wi-Fi is available for debugging.

Terminal controls are also available.

```sh
./"Watch Internet.command" on
./"Watch Internet.command" status
./"Watch Internet.command" off
```

For a first experiment, use a timed trial. Its detached timer restores routing
even if the Terminal window closes.

```sh
./"Watch Internet.command" trial --seconds 125
```

## Stop and restore

Double-click **Watch Internet.command** again, or run its `off` command. The
standalone session closes the tunnel and its temporary macOS DNS and online
service state. Restore Mac Wi-Fi if you previously switched it off, and wait
for the normal network to reconnect.

```sh
./"Watch Internet.command" off
./"Watch Internet.command" status
```

To finish using the watch, stop the Mac helper and tap **Stop session** on the
watch.

```sh
./WatchRelay.command --stop
```

If the normal connection has not returned, turn Mac Wi-Fi on and reconnect it,
then run `off` again. Stop any separately active SFM VPN through its Stop button
or the command below. A timed trial also has its own automatic deadline.

## Optional signed sing-box app

The optional SFM route uses the publisher-signed sing-box Network Extension.
It was tested with Mac Wi-Fi on. On the tested Mac, macOS refused to start this
provider with every ordinary network off. Use the default standalone engine for
that condition.

To prepare SFM, run `./mac/wide/stage sfm`, install the verified package, and
approve its Network Extension through macOS. In SFM, create a **Local** profile
named **WatchRelay**, choose **File → Import** in that profile's creation form,
and select `mac/wide/WatchRelay.json`. Start it successfully once from the app
before using the launcher controls.

```sh
./"Watch Internet.command" on --engine sfm
./"Watch Internet.command" off --engine sfm
```

Keep the WatchRelay profile selected when using these controls. SFM restores
its last selected profile when started externally. Run one tunnel engine at a
time.

To disable or remove SFM, first stop its VPN. Disable any SFM **Always On** or
on-demand setting you enabled. In macOS **System Settings → VPN**, remove the
SFM configuration if you no longer need it. Disable **SFMExtension** under
**General → Login Items & Extensions → Network Extensions**, then move the
SFM app to Trash. These steps concern the optional SFM installation and are
independent of the standalone WatchRelay engine.

## Traffic and privacy boundaries

Watch Internet captures the default IPv4 and IPv6 internet routes. TCP traffic
travels through the authenticated Bluetooth relay to cellular-bound watch
sockets. System DNS is sent through the watch to Cloudflare using TLS-verified
DNS over HTTPS. Local route exceptions and other VPNs can affect routing, so
use the included probes when testing a new setup.

The tested mobile plan provided usable IPv4 egress. The profile gives IPv4 DNS
answers and rejects IPv6 inside the captured tunnel. It also rejects UDP other
than DNS. QUIC-capable applications can use TCP when they offer that fallback.
UDP-only apps need additional relay support.

Mac-wide mode allows 24 active TCP streams and up to 96 waiting local
connections, with a 12-second waiting deadline. Idle connections are reclaimed
under pressure. If the watch disconnects, the active profile has no direct
internet fallback. Switch Watch Internet off to use the Mac's usual connection.
Interrupted requests may need a user retry after Bluetooth reconnects.

The relay preserves end-to-end TLS and does not install a certificate authority.
Its diagnostics record connection state and aggregate counts rather than packet
bodies. Keep exported logs private until reviewed.

## Reproduce the checks

The scripts record results locally under the ignored evidence directory. They
use ordinary sockets with application proxy settings explicitly bypassed.

```sh
./scripts/test-wide-smoke baseline --wifi on
./scripts/test-wide-offline.command
```

The offline script obtains administrator authorization locally, waits for you to
turn Mac Wi-Fi off, checks the negative control, starts a timed tunnel, and checks
fresh system DNS and HTTPS. It then allows time for ordinary apps to be tried.
Restore Wi-Fi when done. The script waits for normal connectivity before
removing the tunnel and comparing the restored route with its baseline.

A passing transport test does not establish every application's behavior.
Confirm a fresh response in each app you intend to rely on.

See the [public test report](test-report.md),
[official sing-box documentation](https://sing-box.sagernet.org/), and
[Apple's Network Extension deployment guide](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
