import 'model.dart';

/// Which languages the user can pick as "the other person's", and which
/// recognizers to try for each (R2, P3).
///
/// Combines the bundled [packs] with what the phone reports ([caps]). A
/// language is offered when it works fully: at least one usable recognizer and
/// offline translation both ways with Vietnamese. The online OS recognizer is
/// usable only on Android and only for languages with consent
/// ([onlineConsent], language codes the user agreed to send to the OS
/// service). Vietnamese is the home language and is never offered.
class LanguageCatalog {
  LanguageCatalog({
    required List<LanguagePack> packs,
    required Capabilities caps,
    required String platform,
    Set<String> onlineConsent = const {},
  }) : _caps = caps,
       _onlineAllowed = _checkPlatform(platform) == 'android',
       _consent = Set.unmodifiable(onlineConsent) {
    final sorted =
        packs.where((p) => p.code != homeCode && _usable(p.code) && caps.translatable.contains(p.code)).toList()
          ..sort((a, b) {
            final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
            return byLabel != 0 ? byLabel : a.code.compareTo(b.code);
          });
    offered = List.unmodifiable(sorted);
  }

  /// Code of the home language, which is always the wearer's.
  static const homeCode = 'vi';

  final Capabilities _caps;
  final bool _onlineAllowed;
  final Set<String> _consent;

  /// The languages to list, sorted by label.
  late final List<LanguagePack> offered;

  /// The recognizers to try for [code], best first: the OS on-device one,
  /// then Whisper, then (with consent, Android only) the OS online one.
  List<RecognizerKind> chain(String code) {
    final have = _caps.recognizers[code] ?? const <RecognizerKind>[];
    return List.unmodifiable([
      for (final kind in RecognizerKind.values)
        if (have.contains(kind) && (kind != RecognizerKind.osOnline || _mayGoOnline(code))) kind,
    ]);
  }

  bool _usable(String code) => chain(code).isNotEmpty;

  bool _mayGoOnline(String code) => _onlineAllowed && _consent.contains(code);

  static String _checkPlatform(String platform) {
    if (platform != 'ios' && platform != 'android') {
      throw ArgumentError.value(platform, 'platform', "must be 'ios' or 'android'");
    }
    return platform;
  }
}
