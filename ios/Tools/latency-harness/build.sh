#!/bin/zsh
# Builds the latency harness from the app's own sources (no copies), optimized like a release build.
# Speaker.swift is iOS only (usesApplicationAudioSession): TTS.swift mirrors its utterance setup.
# Translator.swift needs a macOS 26.4 deployment target: on an older macOS TranslatorShim.swift stands in.
# -D DEBUG lets SharedResources read the language packs from shared/ in this checkout.
set -e
here=${0:A:h}
src=$here/../../Sources
os=$(sw_vers -productVersion)
if [[ $(printf '%s\n' 26.4 $os | sort -V | head -1) == 26.4 ]]; then
  translator=($src/Translate/Translator.swift $here/TranslatorStrategy.swift)
  target=(-target arm64-apple-macos26.4)
else
  echo "macOS $os < 26.4: using TranslatorShim.swift instead of the app's Translator.swift"
  translator=($here/TranslatorShim.swift)
  target=()
fi
swiftc -O -parse-as-library -D DEBUG $target -o $here/latency-harness \
  $src/Audio/VoiceGate.swift $src/Audio/ADPCMDecoder.swift $src/Engine/AudioSources.swift \
  $src/Engine/LiveTranscriber.swift $src/Engine/EngineMapping.swift $src/App/Diagnostics.swift \
  $src/App/TurnAssembler.swift $src/Translate/VietnameseFixup.swift $src/Translate/SubtitleTranslator.swift \
  $src/Core/TextPipeline.swift $src/Core/RuleEngine.swift $src/Core/TermProtector.swift $src/Core/Model.swift \
  $src/Core/Glossary.swift $src/Core/UnicodeText.swift $src/Core/SharedResources.swift $src/Core/VoiceEngine.swift $src/Core/LanguageCatalog.swift \
  $translator $here/Common.swift $here/Experiment.swift $here/BoardSim.swift $here/TTS.swift $here/Them.swift $here/You.swift $here/main.swift
echo "built $here/latency-harness"
