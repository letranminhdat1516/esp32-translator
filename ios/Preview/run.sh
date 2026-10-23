#!/bin/sh
# Builds and opens the phone preview: the real ContentView on the Mac with fake data (no Xcode, no Simulator).
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    PreviewMocks.swift PreviewApp.swift ../Sources/UI/ContentView.swift -o build/phone-preview
exec build/phone-preview
