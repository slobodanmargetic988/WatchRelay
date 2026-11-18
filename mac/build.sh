#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bundle="${WATCHRELAY_MAC_BUILD_DIR:-$PWD/build}/WatchRelay.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun clang -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -Wextra \
    -framework Foundation -framework IOBluetooth \
    main.m RelayFrame.m SocksProxy.m IncomingRfcomm.m AutoTrust.m -o "$bundle/Contents/MacOS/watchrelay"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle/Contents/MacOS/watchrelay"
