import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/engine/engine_api.g.dart',
    swiftOut: 'ios/Runner/Native/EngineApi.g.swift',
    kotlinOut: 'android/app/src/main/kotlin/vn/cicca/livetranslator/engine/EngineApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'vn.cicca.livetranslator.engine'),
  ),
)
enum MissingKind { speechModel, translation, ttsVoice }

enum AudioSessionKind { interrupted, resumed, routeChanged }

enum AudioRoute { headset, phoneMic }

/// `finalText` is the "final" kind; `final` is a reserved word in Dart.
enum MineKind { partial, finalText }

/// Recognizer lists carry `RecognizerKind` names (`osOnDevice`, `whisper`,
/// `osOnline`) because pigeon maps cannot hold enum lists.
class CapabilitiesMsg {
  CapabilitiesMsg({
    required this.recognizers,
    required this.translatable,
    required this.vietnameseVoice,
  });
  Map<String, List<String>> recognizers;
  List<String> translatable;
  bool vietnameseVoice;
}

/// A missing download. [language] is the language code; [from] and [to] are
/// set only for [MissingKind.translation].
class MissingMsg {
  MissingMsg({required this.kind, required this.language, this.from, this.to});
  MissingKind kind;
  String language;
  String? from;
  String? to;
}

class PairMsg {
  PairMsg({required this.home, required this.other, required this.generation});
  String home;
  String other;
  int generation;
}

class MineMsg {
  MineMsg({
    required this.kind,
    required this.text,
    required this.startMs,
    required this.endMs,
  });
  MineKind kind;
  String text;
  int startMs;
  int endMs;
}

class TheirsMsg {
  TheirsMsg({required this.text, this.confidence, required this.generation});
  String text;
  double? confidence;
  int generation;
}

class AudioSessionMsg {
  AudioSessionMsg({required this.kind, this.route});
  AudioSessionKind kind;
  AudioRoute? route;
}

class DownloadMsg {
  DownloadMsg({
    required this.item,
    required this.progress,
    required this.done,
    this.error,
  });
  MissingMsg item;
  double progress;
  bool done;
  String? error;
}

@HostApi()
abstract class VoiceEngineApi {
  CapabilitiesMsg capabilities();
  List<MissingMsg> missing(PairMsg pair);
  @async
  void download(MissingMsg item);
  @async
  void start(PairMsg pair, String recognizerX, List<String> hints);
  void stop();
  void micOn(bool on);

  /// 16-bit little-endian mono PCM.
  void feedTheirAudio(Uint8List pcm16le, int sampleRate);
  @async
  String translate(String text, String from, String to);
  void speak(String text, int id);
  void stopSpeaking();
  void setHints(List<String> hints);
  void openTtsSettings();
}

@FlutterApi()
abstract class VoiceEngineEvents {
  void onMine(MineMsg msg);
  void onTheirs(TheirsMsg msg);
  void onGate(bool open);
  void onTtsStart(int id);
  void onTtsEnd(int id);
  void onAudioSession(AudioSessionMsg msg);
  void onDownload(DownloadMsg msg);
}
