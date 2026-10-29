import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/glossary.dart';
import 'package:live_translator/core/model.dart';

import '../shared_fixtures.dart';

void main() {
  late Directory dir;
  late File file;
  var idCounter = 0;
  final clock = DateTime(2026, 3, 4, 5, 6, 7);

  Future<GlossaryStore> open() => GlossaryStore.open(
    file,
    clock: () => clock,
    newId: () => 'id${++idCounter}',
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('glossary_test');
    file = File('${dir.path}/glossary.json');
    idCounter = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('basic use', () {
    test('starts empty without a file', () async {
      final store = await open();
      expect(store.terms, isEmpty);
      expect(store.recoveredFromCorruption, isFalse);
      expect(file.existsSync(), isFalse);
    });

    test('add stores a user term and survives a relaunch', () async {
      final store = await open();
      final t = await store.add(
        text: '  Bến Thành ',
        variants: ['Ben Thanh'],
        fixed: {'en': 'Ben Thanh Market'},
      );
      expect(t.id, 'id1');
      expect(t.text, 'Bến Thành');
      expect(t.origin, TermOrigin.user);
      expect(store.terms, [t]);

      final again = await open();
      expect(again.terms, [t]);
      // The file is a JSON list of terms.
      final raw = jsonDecode(file.readAsStringSync()) as List;
      expect(raw.single['text'], 'Bến Thành');
    });

    test('update replaces a term by id, remove deletes it', () async {
      final store = await open();
      final a = await store.add(text: 'Zalo');
      final b = await store.add(text: 'Grab');
      final changed = await store.update(
        a.id,
        text: 'Zalo Pay',
        fixed: {'en': 'ZaloPay'},
      );
      expect(changed.id, a.id);
      expect(store.terms.map((t) => t.text), ['Zalo Pay', 'Grab']);
      await store.remove(b.id);
      expect(store.terms.map((t) => t.text), ['Zalo Pay']);
      expect((await open()).terms.single.fixed, {'en': 'ZaloPay'});
    });

    test('update to the same text is not a duplicate of itself', () async {
      final store = await open();
      final a = await store.add(text: 'Zalo');
      await store.update(a.id, text: 'zalo', variants: ['Zalo App']);
      expect(store.terms.single.text, 'zalo');
    });

    test('update or remove of an unknown id is an error', () async {
      final store = await open();
      expect(() => store.update('nope', text: 'x'), throwsA(isA<UnknownTerm>()));
      expect(() => store.remove('nope'), throwsA(isA<UnknownTerm>()));
    });

    test('terms is read-only', () async {
      final store = await open();
      await store.add(text: 'A');
      expect(() => store.terms.add(const Term(id: 'x', text: 'x')), throwsUnsupportedError);
    });

    test('the file is written atomically (no leftover temp file)', () async {
      final store = await open();
      await store.add(text: 'A');
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['glossary.json']);
    });

    test('creates the parent directory', () async {
      final nested = File('${dir.path}/a/b/glossary.json');
      final store = await GlossaryStore.open(nested);
      await store.add(text: 'A');
      expect(nested.existsSync(), isTrue);
    });
  });

  group('change stream', () {
    test('fires on add, update and remove, to several listeners', () async {
      final store = await open();
      final one = <List<String>>[];
      final two = <List<String>>[];
      store.changes.listen((l) => one.add([for (final t in l) t.text]));
      store.changes.listen((l) => two.add([for (final t in l) t.text]));
      final a = await store.add(text: 'A');
      await store.update(a.id, text: 'B');
      await store.remove(a.id);
      await Future<void>.delayed(Duration.zero);
      expect(one, [['A'], ['B'], <String>[]]);
      expect(two, one);
    });

    test('does not fire for a rejected change', () async {
      final store = await open();
      var fired = 0;
      store.changes.listen((_) => fired++);
      await expectLater(store.add(text: ''), throwsA(isA<EmptyText>()));
      await Future<void>.delayed(Duration.zero);
      expect(fired, 0);
    });

    test('is a broadcast stream', () async {
      final store = await open();
      expect(store.changes.isBroadcast, isTrue);
    });
  });

  group('glossary.json cases', () {
    final fixture = loadFixture('glossary');
    final limits = fixture['limits'] as Map<String, dynamic>;

    test('limits', () {
      expect(GlossaryStore.maxTerms, limits['maxTerms']);
      expect(GlossaryStore.maxLength, limits['maxLength']);
      expect(GlossaryStore.maxVariants, limits['maxVariants']);
    });

    void expectError(Object e, Map<String, dynamic> want) {
      expect(e, isA<GlossaryError>());
      expect(e.runtimeType.toString(), want['error']);
      switch (e) {
        case EmptyText(:final field):
          expect(field, want['field']);
        case TooLong(:final field, :final limit):
          expect((field, limit), (want['field'], want['limit']));
        case TooManyVariants(:final limit) || TooManyTerms(:final limit):
          expect(limit, want['limit']);
        case ForbiddenCharacter(:final field, :final codePoint):
          expect((field, codePoint), (want['field'], want['codePoint']));
        case DuplicateTerm(:final field, :final value):
          expect((field, value), (want['field'], want['value']));
        default:
          break;
      }
    }

    for (final c in casesOf(fixture, 'cases')) {
      test(c['name'] as String, () async {
        final store = await open();
        final existing = <Term>[
          for (final e in optionalCasesOf(c, 'existing'))
            await store.add(text: e['text'] as String, variants: strings(e['variants']), fixed: stringMap(e['fixed'])),
        ];
        final input = c['input'] as Map<String, dynamic>?;
        final target = c['targetId'] as String? ?? (c['target'] == null ? null : existing[c['target'] as int].id);
        final before = file.existsSync() ? file.readAsStringSync() : null;
        final want = c['expect'] as Map<String, dynamic>;
        Future<Term?> run() async => switch (c['op']) {
          'add' => store.add(
            text: input!['text'] as String,
            variants: strings(input['variants']),
            fixed: stringMap(input['fixed']),
          ),
          'update' => store.update(
            target!,
            text: input!['text'] as String,
            variants: strings(input['variants']),
            fixed: stringMap(input['fixed']),
          ),
          'remove' => store.remove(target!).then((_) => null),
          final op => throw StateError('unknown op $op'),
        };
        if (want['ok'] == true) {
          final t = await run();
          if (want.containsKey('text')) expect(t!.text, want['text']);
          if (want.containsKey('variants')) expect(t!.variants, strings(want['variants']));
          if (want.containsKey('fixed')) expect(t!.fixed, stringMap(want['fixed']));
          if (want.containsKey('allTexts')) expect(store.terms.map((t) => t.text), strings(want['allTexts']));
          if (t != null) expect(t.origin, TermOrigin.user);
        } else {
          Object? caught;
          try {
            await run();
          } catch (e) {
            caught = e;
          }
          expect(caught, isNotNull, reason: 'should throw ${want['error']}');
          expectError(caught!, want);
          // A rejected change leaves the list and the file untouched.
          expect(store.terms, existing);
          expect(file.existsSync() ? file.readAsStringSync() : null, before);
        }
      });
    }

    group('load', () {
      for (final c in casesOf(fixture, 'load')) {
        test(c['name'] as String, () async {
          final content = c['content'] as String;
          file.writeAsStringSync(content);
          final store = await open();
          expect(store.terms.map((t) => t.text), strings(c['texts']));
          expect(store.recoveredFromCorruption, c['recovered']);
          if (c['recovered'] == true) {
            // Dart-specific: the file is set aside with a time stamp.
            expect(file.existsSync(), isFalse);
            final aside = File('${dir.path}/glossary.corrupt-20260304-050607.json');
            expect(aside.readAsStringSync(), content);
            // and the store works again
            await store.add(text: 'A');
            expect((await open()).terms.single.text, 'A');
            expect((await open()).recoveredFromCorruption, isFalse);
          }
        });
      }
    });
  });

  group('limits and rejections, not fixture-driven', () {
    test('errors are glossary errors', () {
      expect(const TooManyTerms(500), isA<GlossaryError>());
    });

    test('a rejected change leaves the file and the list untouched', () async {
      final store = await open();
      await store.add(text: 'A');
      final before = file.readAsStringSync();
      await expectLater(store.add(text: 'A'), throwsA(isA<DuplicateTerm>()));
      expect(file.readAsStringSync(), before);
      expect(store.terms.length, 1);
    });
  });

  group('corrupt file, not fixture-driven', () {
    test('not UTF-8: renamed aside, empty glossary, flag set', () async {
      file.writeAsBytesSync([0xff, 0xfe]);
      final store = await open();
      expect(store.terms, isEmpty);
      expect(store.recoveredFromCorruption, isTrue);
      expect(file.existsSync(), isFalse);
      final aside = File('${dir.path}/glossary.corrupt-20260304-050607.json');
      expect(aside.readAsBytesSync(), [0xff, 0xfe]);
      await store.add(text: 'A');
      expect((await open()).terms.single.text, 'A');
    });

    test('two corrupt files in the same second do not overwrite each other', () async {
      file.writeAsStringSync('first');
      await open();
      file.writeAsStringSync('second');
      await open();
      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
      expect(names.length, 2);
      expect(
        names.map((n) => File('${dir.path}/$n').readAsStringSync()).toSet(),
        {'first', 'second'},
      );
    });
  });

  test('concurrent changes are all kept', () async {
    final store = await open();
    await Future.wait([for (var i = 0; i < 20; i++) store.add(text: 'term $i')]);
    expect(store.terms.length, 20);
    expect((await open()).terms.length, 20);
  });

  test('a write failure is reported and changes nothing', () async {
    final store = await open();
    await store.add(text: 'A');
    // A directory where the file should be makes the rename fail.
    file.deleteSync();
    Directory(file.path).createSync();
    await expectLater(store.add(text: 'B'), throwsA(isA<GlossaryWriteError>()));
    expect(store.terms.map((t) => t.text), ['A']);
  });
}
