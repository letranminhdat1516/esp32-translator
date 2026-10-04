#!/bin/zsh
# Builds the harness from the app's own sources (no copies), optimized like a release build.
set -e
here=${0:A:h}
src=$here/../../Sources
swiftc -O -parse-as-library -o $here/vi-harness \
  $src/Audio/VoiceGate.swift $src/Audio/AudioSources.swift $src/Audio/ADPCMDecoder.swift \
  $src/Speech/LiveTranscriber.swift $src/App/Diagnostics.swift $src/App/TurnAssembler.swift \
  $src/Translate/VietnameseFixup.swift \
  $here/LegacyVoiceGate.swift $here/Assemble.swift $here/main.swift
echo "built $here/vi-harness"
swiftc -O -parse-as-library -o $here/vi-translate $src/Translate/VietnameseFixup.swift $here/translate.swift
echo "built $here/vi-translate"
