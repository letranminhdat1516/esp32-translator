import 'package:flutter_test/flutter_test.dart';

import 'shared_fixtures.dart';

void main() {
  test('casesOf returns the objects of a list', () {
    expect(casesOf({'a': [{'x': 1}]}, 'a'), [{'x': 1}]);
  });

  test('casesOf throws on a missing key, so a typo in a test cannot skip cases', () {
    expect(() => casesOf({'a': []}, 'b'), throwsA(isA<FixtureError>()));
    expect(() => casesOf({'a': null}, 'a'), throwsA(isA<FixtureError>()));
  });

  test('optionalCasesOf treats a missing key as empty', () {
    expect(optionalCasesOf({'a': []}, 'b'), isEmpty);
    expect(optionalCasesOf({'a': [{'x': 1}]}, 'a'), [{'x': 1}]);
  });
}
