#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra \
    -framework Foundation RelayFrame.m RelayFrameTests.m -o build/frame-tests
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra \
    -framework Foundation SocksProxy.m SocksProxyTests.m -o build/socks-tests
xcrun clang -mmacosx-version-min=13.0 -fobjc-arc -Wall -Wextra \
    -framework Foundation AutoTrust.m AutoTrustTests.m -o build/auth-tests
build/frame-tests
build/socks-tests
exec build/auth-tests
