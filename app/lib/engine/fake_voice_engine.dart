import 'dart:async';
import 'dart:typed_data';

import '../core/model.dart';
import 'voice_engine.dart';

/// In-memory [VoiceEngine] for Dart tests. No platform channels; every
/// response is scriptable and every call is recorded.
class FakeVoiceEngine implements VoiceEngine {
  FakeVoiceEngine({
    this.capabilitiesResult = const Capabilities(
      recognizers: {},
      translatable: {},
      vietnameseVoice: true,
    ),
  });

  Capabilities capabilitiesResult;

  /// Returned by [missing]; set per test.
  List<MissingMsg> missingResult = [];

  /// Translations by source text. A text with no entry is returned unchanged.
  final Map<String, String> translations = {};

  /// `speak` calls in order.
  final List<({String text, int id})> spoken = [];
  final List<MissingMsg> downloaded = [];
  final List<({PairMsg pair, String recognizerX, List<String> hints})> starts =
      [];
  final List<({Int16List pcm, int sampleRate})> fed = [];
  final List<bool> micStates = [];
  List<String> hints = const [];
  int stopCount = 0;
  int stopSpeakingCount = 0;
  int openTtsSettingsCount = 0;

  bool _failTranslate = false;

  /// Makes the next [translate] throw [EngineError.translateFailed].
  void failNextTranslate() => _failTranslate = true;

  final _mine = StreamController<MineMsg>.broadcast();
  final _theirs = StreamController<TheirsMsg>.broadcast();
  final _gate = StreamController<bool>.broadcast();
  final _ttsStart = StreamController<int>.broadcast();
  final _ttsEnd = StreamController<int>.broadcast();
  final _audioSession = StreamController<AudioSessionMsg>.broadcast();
  final _download = StreamController<DownloadMsg>.broadcast();

  void emitMine(MineMsg msg) => _mine.add(msg);
  void emitTheirs(TheirsMsg msg) => _theirs.add(msg);
  void emitGate(bool open) => _gate.add(open);
  void emitTtsStart(int id) => _ttsStart.add(id);
  void emitTtsEnd(int id) => _ttsEnd.add(id);
  void emitAudioSession(AudioSessionMsg msg) => _audioSession.add(msg);
  void emitDownload(DownloadMsg msg) => _download.add(msg);

  @override
  Future<Capabilities> capabilities() async => capabilitiesResult;

  @override
  Future<List<MissingMsg>> missing(PairMsg pair) async => missingResult;

  @override
  Future<void> downloadItem(MissingMsg item) async => downloaded.add(item);

  @override
  Future<void> start(
    PairMsg pair,
    String recognizerX,
    List<String> hints,
  ) async {
    starts.add((pair: pair, recognizerX: recognizerX, hints: hints));
  }

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> micOn(bool on) async => micStates.add(on);

  @override
  Future<void> feedTheirAudio(Int16List pcm, int sampleRate) async {
    fed.add((pcm: pcm, sampleRate: sampleRate));
  }

  @override
  Future<String> translate(String text, String from, String to) async {
    if (_failTranslate) {
      _failTranslate = false;
      throw EngineError.translateFailed;
    }
    return translations[text] ?? text;
  }

  @override
  Future<void> speak(String text, int id) async {
    spoken.add((text: text, id: id));
  }

  @override
  Future<void> stopSpeaking() async => stopSpeakingCount++;

  @override
  Future<void> setHints(List<String> hints) async => this.hints = hints;

  @override
  Future<void> openTtsSettings() async => openTtsSettingsCount++;

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
}
