import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/model.dart';
import 'package:live_translator/core/text_pipeline.dart';

import '../shared_fixtures.dart';

/// Cases: shared/fixtures/text_pipeline.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('text_pipeline');
  final packs = {
    for (final e in (fixture['packs'] as Map<String, dynamic>).entries)
      e.key: () {
        final spec = e.value as Map<String, dynamic>;
        final file = spec['file'] as String?;
        return file != null ? sharedPack(file) : LanguagePack.fromJson(spec);
      }(),
  };

  TextPipeline pipelineOf(Map<String, dynamic> c) => TextPipeline(
    home: packs[c['home']]!,
    other: packs[c['other']]!,
    glossary: [for (final j in (c['glossary'] as List?) ?? const []) termOf(j as Map<String, dynamic>)],
    placeholders: stringMap(c['placeholders']),
    defaultPlaceholder: fixture['defaultPlaceholder'] as String,
  );

  Direction directionOf(Map<String, dynamic> c) => Direction.values.byName(c['direction'] as String);

  group('prepare / finish', () {
    for (final c in casesOf(fixture, 'prepare')) {
      test(c['name'] as String, () {
        final p = pipelineOf(c);
        final prep = p.prepare(c['input'] as String, directionOf(c));
        expect(prep.text, c['prepared']);
        for (final f in optionalCasesOf(c, 'finish')) {
          expect(p.finish(f['translated'] as String, prep), f['expected']);
        }
      });
    }
  });

  group('translate', () {
    for (final c in casesOf(fixture, 'translate')) {
      test(c['name'] as String, () async {
        final p = pipelineOf(c);
        final responses = strings(c['responses']);
        final requests = <String>[];
        final out = await p.translate(c['input'] as String, directionOf(c), (s) async {
          requests.add(s);
          return responses[requests.length - 1];
        });
        expect(requests, strings(c['requests']));
        expect(out, c['expected']);
        expect(p.lostPlaceholders, c['lostPlaceholders']);
      });
    }

    // Not fixture-driven: an exception thrown by the injected translator.
    test('a translator error propagates', () {
      final p = TextPipeline(home: packs['vi']!, other: packs['en']!);
      expect(
        p.translate('xin chào', Direction.mine, (s) async => throw StateError('boom')),
        throwsStateError,
      );
    });
  });
}
