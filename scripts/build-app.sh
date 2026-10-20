#!/bin/sh
# Builds the Coastline app package and prints compact diagnostics.
# Without Xcode, the macOS 27 SDK's SwiftUI needs a macro plugin that only Xcode ships, so we
# build against the macOS 26.x SDK from the Command Line Tools instead (deployment target is 15).
cd "$(dirname "$0")/../Coastline" || exit 1
if ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
    SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
    [ -n "$SDK" ] && export SDKROOT="$SDK"
fi
swift build "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*(error|warning):|^error:|Build complete" | grep -v "search path\|/.build/checkouts/" | sort -u
