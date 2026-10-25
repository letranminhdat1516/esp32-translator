import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/language_catalog.dart';
import 'package:live_translator/core/model.dart';

LanguagePack pack(String code, String label) => LanguagePack(
  code: code,
  appleLocale: '$code-A',
  androidLocale: '$code-B',
  whisperCode: code,
  label: label,
  labelLatin: code.toUpperCase(),
  script: Script.latin,
);

Capabilities caps(
  Map<String, List<RecognizerKind>> recognizers,
  Set<String> translatable,
) => Capabilities(
  recognizers: recognizers,
  translatable: translatable,
  vietnameseVoice: true,
);

const onDevice = RecognizerKind.osOnDevice;
const whisper = RecognizerKind.whisper;
const online = RecognizerKind.osOnline;

void main() {
  final packs = [
    pack('vi', 'Tiếng Việt'),
    pack('en', 'English'),
    pack('ja', '日本語'),
    pack('fr', 'Français'),
    pack('de', 'Deutsch'),
  ];

  List<String> offered(
    Capabilities c, {
    String platform = 'android',
    Set<String> consent = const {},
  }) => LanguageCatalog(
    packs: packs,
    caps: c,
    platform: platform,
    onlineConsent: consent,
  ).offered.map((p) => p.code).toList();

  group('offered', () {
    test('needs a recognizer and translation, and is sorted by label', () {
      final c = caps(
        {
          'vi': [whisper],
          'en': [whisper],
          'ja': [whisper],
          'fr': [onDevice],
          'de': [whisper],
        },
        {'vi', 'en', 'ja', 'fr', 'de'},
      );
      // Deutsch, English, Français, 日本語
      expect(offered(c), ['de', 'en', 'fr', 'ja']);
    });

    test('a language without translation is not offered', () {
      final c = caps(
        {'en': [whisper], 'ja': [whisper]},
        {'en'},
      );
      expect(offered(c), ['en']);
    });

    test('a language without any usable recognizer is not offered', () {
      final c = caps(
        {'en': [whisper], 'ja': const [], 'fr': [online]},
        {'en', 'ja', 'fr'},
      );
      // fr has only the online recognizer and no consent
      expect(offered(c), ['en']);
    });

    test('a language missing from the recognizers map is not offered', () {
      final c = caps({'en': [whisper]}, {'en', 'ja'});
      expect(offered(c), ['en']);
    });

    test('Vietnamese, the home language, is never offered', () {
      final c = caps(
        {'vi': [whisper], 'en': [whisper]},
        {'vi', 'en'},
      );
      expect(offered(c), ['en']);
    });

    test('capabilities for languages without a pack are ignored', () {
      final c = caps(
        {'xx': [whisper], 'en': [whisper]},
        {'xx', 'en'},
      );
      expect(offered(c), ['en']);
    });

    test('osOnline counts only with consent for that language', () {
      final c = caps(
        {'en': [online], 'ja': [online]},
        {'en', 'ja'},
      );
      expect(offered(c), isEmpty);
      expect(offered(c, consent: {'en'}), ['en']);
      expect(offered(c, consent: {'en', 'ja'}), ['en', 'ja']);
    });

    test('osOnline never counts on iOS', () {
      final c = caps({'en': [online]}, {'en'});
      expect(offered(c, platform: 'ios', consent: {'en'}), isEmpty);
    });

    test('nothing is offered without capabilities', () {
      expect(offered(caps(const {}, const {})), isEmpty);
    });

    test('the list is read-only', () {
      final catalog = LanguageCatalog(
        packs: packs,
        caps: caps({'en': [whisper]}, {'en'}),
        platform: 'android',
      );
      expect(() => catalog.offered.add(packs.first), throwsUnsupportedError);
    });

    test('packs sharing a label keep a stable order by code', () {
      final c = caps(
        {'b': [whisper], 'a': [whisper]},
        {'a', 'b'},
      );
      final catalog = LanguageCatalog(
        packs: [pack('b', 'Same'), pack('a', 'Same')],
        caps: c,
        platform: 'ios',
      );
      expect(catalog.offered.map((p) => p.code), ['a', 'b']);
    });
  });

  group('chain', () {
    final all = caps(
      {
        'en': [online, whisper, onDevice],
        'ja': [whisper, online],
        'fr': [onDevice],
        'de': const [],
      },
      {'en', 'ja', 'fr', 'de'},
    );

    LanguageCatalog catalog(String platform, [Set<String> consent = const {}]) =>
        LanguageCatalog(
          packs: packs,
          caps: all,
          platform: platform,
          onlineConsent: consent,
        );

    test('order is on-device OS, Whisper, online OS', () {
      expect(catalog('android', {'en'}).chain('en'), [onDevice, whisper, online]);
    });

    test('online OS only with consent', () {
      expect(catalog('android').chain('en'), [onDevice, whisper]);
      expect(catalog('android', {'ja'}).chain('en'), [onDevice, whisper]);
      expect(catalog('android', {'ja'}).chain('ja'), [whisper, online]);
    });

    test('on iOS the chain never has the online recognizer', () {
      expect(catalog('ios', {'en', 'ja'}).chain('en'), [onDevice, whisper]);
      expect(catalog('ios', {'ja'}).chain('ja'), [whisper]);
    });

    test('unknown or empty languages give an empty chain', () {
      expect(catalog('android').chain('de'), isEmpty);
      expect(catalog('android').chain('zz'), isEmpty);
    });

    test('the Note 9 case: Whisper first, online last, no on-device', () {
      final note9 = LanguageCatalog(
        packs: packs,
        caps: caps({'en': [whisper, online]}, {'en'}),
        platform: 'android',
        onlineConsent: {'en'},
      );
      expect(note9.chain('en'), [whisper, online]);
    });

    test('the chain is read-only', () {
      expect(() => catalog('ios').chain('fr').add(whisper), throwsUnsupportedError);
    });
  });

  test('an unknown platform is rejected', () {
    expect(
      () => LanguageCatalog(packs: packs, caps: caps(const {}, const {}), platform: 'web'),
      throwsArgumentError,
    );
  });

  test('the home language is Vietnamese', () {
    expect(LanguageCatalog.homeCode, 'vi');
  });
}
