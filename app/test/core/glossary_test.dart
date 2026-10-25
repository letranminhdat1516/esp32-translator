import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/core/glossary.dart';
import 'package:live_translator/core/model.dart';

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

  group('limits and rejections', () {
    test('text must not be empty or blank', () async {
      final store = await open();
      await expectLater(store.add(text: ''), throwsA(isA<EmptyText>()));
      await expectLater(store.add(text: '   '), throwsA(isA<EmptyText>()));
      await expectLater(store.add(text: 'A', variants: ['']), throwsA(isA<EmptyText>()));
      await expectLater(store.add(text: 'A', fixed: {'en': ' '}), throwsA(isA<EmptyText>()));
      await expectLater(store.add(text: 'A', fixed: {'': 'x'}), throwsA(isA<EmptyText>()));
    });

    test('64 characters are allowed, 65 are not (term, variant, fixed)', () async {
      final store = await open();
      final ok = 'a' * 64;
      final long = 'a' * 65;
      await store.add(text: ok);
      await expectLater(store.add(text: long), throwsA(isA<TooLong>()));
      await expectLater(store.add(text: 'B', variants: [long]), throwsA(isA<TooLong>()));
      await expectLater(store.add(text: 'C', fixed: {'en': long}), throwsA(isA<TooLong>()));
    });

    test('length counts characters, not UTF-16 units', () async {
      final store = await open();
      // 64 letters outside the BMP: 128 UTF-16 units
      await store.add(text: '\u{1D400}' * 64);
      await expectLater(store.add(text: '\u{1D400}' * 65), throwsA(isA<TooLong>()));
    });

    test('8 variants are allowed, 9 are not', () async {
      final store = await open();
      await store.add(text: 'A', variants: [for (var i = 0; i < 8; i++) 'v$i']);
      await expectLater(
        store.add(text: 'B', variants: [for (var i = 0; i < 9; i++) 'w$i']),
        throwsA(isA<TooManyVariants>()),
      );
    });

    test('500 terms are allowed, the 501st is not', () async {
      final store = await open();
      for (var i = 0; i < 500; i++) {
        await store.add(text: 'term $i');
      }
      expect(store.terms.length, 500);
      await expectLater(store.add(text: 'one more'), throwsA(isA<TooManyTerms>()));
      expect(store.terms.length, 500);
    });

    test('control characters are rejected', () async {
      final store = await open();
      for (final c in ['\u0000', '\u0007', '\n', '\t', '\u007f', '\u0085', '\u009f']) {
        await expectLater(
          store.add(text: 'a${c}b'),
          throwsA(isA<ForbiddenCharacter>()),
          reason: 'U+${c.codeUnitAt(0).toRadixString(16)}',
        );
      }
      await expectLater(store.add(text: 'A', variants: ['x\u0001']), throwsA(isA<ForbiddenCharacter>()));
      await expectLater(store.add(text: 'A', fixed: {'en': 'x\u0001'}), throwsA(isA<ForbiddenCharacter>()));
    });

    test('bidi override characters are rejected', () async {
      final store = await open();
      final bad = [
        for (var c = 0x202a; c <= 0x202e; c++) c,
        for (var c = 0x2066; c <= 0x2069; c++) c,
      ];
      for (final c in bad) {
        await expectLater(
          store.add(text: 'a${String.fromCharCode(c)}b'),
          throwsA(isA<ForbiddenCharacter>()),
          reason: 'U+${c.toRadixString(16)}',
        );
      }
      // neighbours are fine
      await store.add(text: 'a\u2030b');
      await store.add(text: 'a\u2065b');
    });

    test('duplicates are rejected, case-insensitively, across variants', () async {
      final store = await open();
      await store.add(text: 'Grab', variants: ['Grab Car']);
      await expectLater(store.add(text: 'grab'), throwsA(isA<DuplicateTerm>()));
      await expectLater(store.add(text: 'Other', variants: ['GRAB CAR']), throwsA(isA<DuplicateTerm>()));
      await expectLater(store.add(text: 'X', variants: ['x']), throwsA(isA<DuplicateTerm>()));
      await expectLater(store.add(text: 'Y', variants: ['v', 'V']), throwsA(isA<DuplicateTerm>()));
    });

    test('a term with regex characters is accepted as plain text', () async {
      final store = await open();
      final t = await store.add(text: r'C++ (.*)[a-z]$');
      expect(t.text, r'C++ (.*)[a-z]$');
    });

    test('errors are typed and name the field', () async {
      final store = await open();
      try {
        await store.add(text: 'ok', variants: ['fine', 'a' * 70]);
        fail('should throw');
      } on TooLong catch (e) {
        expect(e.field, 'variants[1]');
        expect(e.limit, 64);
      }
      try {
        await store.add(text: 'a\u202eb');
        fail('should throw');
      } on ForbiddenCharacter catch (e) {
        expect(e.field, 'text');
        expect(e.codePoint, 0x202e);
      }
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

  group('corrupt file', () {
    for (final (name, content) in [
      ('not json', '{oops'),
      ('not a list', '{"a": 1}'),
      ('empty file', ''),
      ('not UTF-8', null),
      ('entry of the wrong type', '[1]'),
      ('entry missing a field', '[{"id":"a"}]'),
      (
        'entry over the limits',
        '[{"id":"a","text":"${'x' * 100}","variants":[],"fixed":{},"origin":"user"}]',
      ),
    ]) {
      test('$name: renamed aside, empty glossary, flag set', () async {
        if (content == null) {
          file.writeAsBytesSync([0xff, 0xfe]);
        } else {
          file.writeAsStringSync(content);
        }
        final store = await open();
        expect(store.terms, isEmpty);
        expect(store.recoveredFromCorruption, isTrue);
        expect(file.existsSync(), isFalse);
        final aside = File('${dir.path}/glossary.corrupt-20260304-050607.json');
        expect(aside.existsSync(), isTrue);
        if (content != null) {
          expect(aside.readAsStringSync(), content);
        } else {
          expect(aside.readAsBytesSync(), [0xff, 0xfe]);
        }
        // and the store works again
        await store.add(text: 'A');
        expect((await open()).terms.single.text, 'A');
        expect((await open()).recoveredFromCorruption, isFalse);
      });
    }

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
