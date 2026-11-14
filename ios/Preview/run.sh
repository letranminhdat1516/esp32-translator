#!/bin/sh
# Builds and opens the phone preview: the real ContentView on the Mac with fake data (no Xcode, no Simulator).
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -DDEBUG -parse-as-library -target arm64-apple-macos15.0 \
    PreviewApp.swift ../Sources/UI/ContentView.swift ../Sources/UI/UIState.swift ../Sources/UI/Copy.swift ../Sources/UI/LanguageSheet.swift ../Sources/UI/ReadinessView.swift ../Sources/UI/GlossaryView.swift ../Sources/UI/UISamples.swift ../Sources/Core/Model.swift ../Sources/Core/BoardLink.swift ../Sources/Core/BoardProtocol.swift ../Sources/Core/SessionMachine.swift ../Sources/Core/VoiceEngine.swift -o build/phone-preview
exec build/phone-preview
