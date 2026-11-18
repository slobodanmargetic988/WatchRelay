#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
mkdir -p build
temporary=$(mktemp -d build/.dns-owner.XXXXXX)
trap 'rm -f -- "$temporary/dns-owner"; rmdir -- "$temporary"' EXIT
xcrun --sdk macosx clang -std=gnu11 -Wall -Wextra -Werror -O2 \
    -framework CoreFoundation -framework SystemConfiguration \
    DNSOwner.c -o "$temporary/dns-owner"
mv -f -- "$temporary/dns-owner" build/dns-owner
