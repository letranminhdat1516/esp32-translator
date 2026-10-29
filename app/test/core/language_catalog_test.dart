import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/language_catalog.dart';
import 'package:live_translator/core/model.dart';

import '../shared_fixtures.dart';

LanguagePack pack(String code, String label) => LanguagePack(
  code: code,
  appleLocale: '$code-A',
  androidLocale: '$code-B',
  whisperCode: code,
  label: label,
  labelLatin: code.toUpperCase(),
  script: Script.latin,
);

List<LanguagePack> packsOf(Object? json) => [
  for (final p in json as List) pack((p as Map)['code'] as String, p['label'] as String),
];

Capabilities capsOf(Map<String, dynamic> json) => Capabilities(
  recognizers: {
    for (final e in (json['recognizers'] as Map<String, dynamic>).entries)
      e.key: [for (final k in e.value as List) RecognizerKind.values.byName(k as String)],
  },
  translatable: strings(json['translatable']).toSet(),
  vietnameseVoice: true,
);

/// Cases: shared/fixtures/language_catalog.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('language_catalog');
  final packs = packsOf(fixture['packs']);

  LanguageCatalog catalogOf(Map<String, dynamic> c) => LanguageCatalog(
    packs: c['packs'] == null ? packs : packsOf(c['packs']),
    caps: capsOf(c['caps'] as Map<String, dynamic>),
    platform: c['platform'] as String,
    onlineConsent: strings(c['consent']).toSet(),
  );

  group('offered', () {
    for (final c in casesOf(fixture, 'offered')) {
      test(c['name'] as String, () {
        expect(catalogOf(c).offered.map((p) => p.code), strings(c['expected']));
      });
    }
  });

  group('chain', () {
    test('RecognizerKind order is the chain order', () {
      expect(RecognizerKind.values.map((k) => k.name), strings(fixture['chainOrder']));
    });

    for (final c in casesOf(fixture, 'chain')) {
      test(c['name'] as String, () {
        expect(catalogOf(c).chain(c['code'] as String).map((k) => k.name), strings(c['expected']));
      });
    }
  });

  test('an unknown platform is rejected', () {
    for (final p in strings(fixture['invalidPlatforms'])) {
      expect(
        () => LanguageCatalog(packs: packs, caps: capsOf({'recognizers': <String, dynamic>{}, 'translatable': []}), platform: p),
        throwsArgumentError,
        reason: p,
      );
    }
  });

  test('the home language is Vietnamese', () {
    expect(LanguageCatalog.homeCode, fixture['homeCode']);
  });

  // Not fixture-driven: Dart list immutability.
  test('offered and chain are read-only', () {
    final catalog = LanguageCatalog(
      packs: packs,
      caps: capsOf({'recognizers': {'en': ['whisper']}, 'translatable': ['en']}),
      platform: 'android',
    );
    expect(() => catalog.offered.add(packs.first), throwsUnsupportedError);
    expect(() => catalog.chain('en').add(RecognizerKind.whisper), throwsUnsupportedError);
  });
}
