import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/model.dart';
import 'engine_api.g.dart';

export 'engine_api.g.dart'
    show
        AudioRoute,
        AudioSessionKind,
        AudioSessionMsg,
        CapabilitiesMsg,
        DownloadMsg,
        MineKind,
        MineMsg,
        MissingKind,
        MissingMsg,
        PairMsg,
        TheirsMsg;

/// Typed failures of the native engine. Native code reports them as a
/// `PlatformException` whose `code` is the enum name.
enum EngineError implements Exception {
  translateFailed,
  notReady,
  downloadFailed;

  static EngineError? fromCode(String code) => values.asNameMap()[code];
}

/// Converts the wire form of [CapabilitiesMsg] into the app model.
extension CapabilitiesMsgModel on CapabilitiesMsg {
  Capabilities toModel() => Capabilities(
    recognizers: {
      for (final e in recognizers.entries)
        e.key: [
          for (final name in e.value)
            RecognizerKind.values.asNameMap()[name] ??
                (throw FormatException('unknown recognizer "$name"')),
        ],
    },
    translatable: translatable.toSet(),
    vietnameseVoice: vietnameseVoice,
  );
}

/// Bytes of [pcm] as 16-bit little-endian samples (all targets are
/// little-endian). The result is a view; it shares memory with [pcm].
Uint8List pcm16leBytes(Int16List pcm) =>
    pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);

/// The one native engine per platform: mic, voice gate, recognizers, offline
/// translation and TTS. Events are broadcast streams.
abstract class VoiceEngine {
  Future<Capabilities> capabilities();
  Future<List<MissingMsg>> missing(PairMsg pair);

  /// The `download` call. Named `downloadItem` because the `download` event
  /// stream takes the plain name.
  Future<void> downloadItem(MissingMsg item);
  Future<void> start(PairMsg pair, String recognizerX, List<String> hints);
  Future<void> stop();
  Future<void> micOn(bool on);
  Future<void> feedTheirAudio(Int16List pcm, int sampleRate);

  /// Throws [EngineError] on failure; the caller decides the fallback.
  Future<String> translate(String text, String from, String to);
  Future<void> speak(String text, int id);
  Future<void> stopSpeaking();
  Future<void> setHints(List<String> hints);
  Future<void> openTtsSettings();

  Stream<MineMsg> get mine;
  Stream<TheirsMsg> get theirs;
  Stream<bool> get gate;
  Stream<int> get ttsStart;
  Stream<int> get ttsEnd;
  Stream<AudioSessionMsg> get audioSession;
  Stream<DownloadMsg> get download;
}

/// [VoiceEngine] backed by the pigeon channel.
class PlatformVoiceEngine implements VoiceEngine, VoiceEngineEvents {
  PlatformVoiceEngine({VoiceEngineApi? api}) : _api = api ?? VoiceEngineApi() {
    VoiceEngineEvents.setUp(this);
  }

  final VoiceEngineApi _api;
  final _mine = StreamController<MineMsg>.broadcast();
  final _theirs = StreamController<TheirsMsg>.broadcast();
  final _gate = StreamController<bool>.broadcast();
  final _ttsStart = StreamController<int>.broadcast();
  final _ttsEnd = StreamController<int>.broadcast();
  final _audioSession = StreamController<AudioSessionMsg>.broadcast();
  final _download = StreamController<DownloadMsg>.broadcast();

  /// Maps a native `PlatformException` to [EngineError] when its code names
  /// one; anything else is rethrown with its original stack.
  Future<T> _call<T>(Future<T> Function() call, [EngineError? fallback]) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      final error = EngineError.fromCode(e.code) ?? fallback;
      if (error == null) rethrow;
      throw error;
    }
  }

  @override
  Future<Capabilities> capabilities() async =>
      (await _api.capabilities()).toModel();

  @override
  Future<List<MissingMsg>> missing(PairMsg pair) => _api.missing(pair);

  @override
  Future<void> downloadItem(MissingMsg item) =>
      _call(() => _api.download(item), EngineError.downloadFailed);

  @override
  Future<void> start(PairMsg pair, String recognizerX, List<String> hints) =>
      _call(() => _api.start(pair, recognizerX, hints));

  @override
  Future<void> stop() => _api.stop();

  @override
  Future<void> micOn(bool on) => _api.micOn(on);

  @override
  Future<void> feedTheirAudio(Int16List pcm, int sampleRate) =>
      _api.feedTheirAudio(pcm16leBytes(pcm), sampleRate);

  @override
  Future<String> translate(String text, String from, String to) =>
      _call(() => _api.translate(text, from, to), EngineError.translateFailed);

  @override
  Future<void> speak(String text, int id) => _api.speak(text, id);

  @override
  Future<void> stopSpeaking() => _api.stopSpeaking();

  @override
  Future<void> setHints(List<String> hints) => _api.setHints(hints);

  @override
  Future<void> openTtsSettings() => _api.openTtsSettings();

  @override
  Stream<MineMsg> get mine => _mine.stream;
  @override
  Stream<TheirsMsg> get theirs => _theirs.stream;
  @override
  Stream<bool> get gate => _gate.stream;
  @override
  Stream<int> get ttsStart => _ttsStart.stream;
  @override
  Stream<int> get ttsEnd => _ttsEnd.stream;
  @override
  Stream<AudioSessionMsg> get audioSession => _audioSession.stream;
  @override
  Stream<DownloadMsg> get download => _download.stream;

  @override
  void onMine(MineMsg msg) => _mine.add(msg);
  @override
  void onTheirs(TheirsMsg msg) => _theirs.add(msg);
  @override
  void onGate(bool open) => _gate.add(open);
  @override
  void onTtsStart(int id) => _ttsStart.add(id);
  @override
  void onTtsEnd(int id) => _ttsEnd.add(id);
  @override
  void onAudioSession(AudioSessionMsg msg) => _audioSession.add(msg);
  @override
  void onDownload(DownloadMsg msg) => _download.add(msg);
}
