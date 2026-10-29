import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/adpcm.dart';

import '../shared_fixtures.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

// Reference encoder: the firmware's firmware/main/adpcm.c, in Dart.
const _indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];

int _encodeSample(List<int> st, int sample) {
  // st = [predictor, index]
  final step0 = adpcmStepTable[st[1]];
  var step = step0;
  var diff = sample - st[0];
  var code = 0;
  if (diff < 0) {
    code = 8;
    diff = -diff;
  }
  var delta = step >> 3;
  if (diff >= step) {
    code |= 4;
    diff -= step;
    delta += step;
  }
  step >>= 1;
  if (diff >= step) {
    code |= 2;
    diff -= step;
    delta += step;
  }
  step >>= 1;
  if (diff >= step) {
    code |= 1;
    delta += step;
  }
  final pred = st[0] + ((code & 8) != 0 ? -delta : delta);
  st[0] = pred.clamp(-32768, 32767);
  st[1] = (st[1] + _indexTable[code]).clamp(0, 88);
  return code;
}

Uint8List encodePacket(int seq, List<int> samples, {int predictor = 0, int index = 0}) {
  final st = [predictor, index];
  final out = <int>[
    seq & 0xff,
    (seq >> 8) & 0xff,
    predictor & 0xff,
    (predictor >> 8) & 0xff,
    index,
  ];
  for (var i = 0; i < samples.length; i += 2) {
    final lo = _encodeSample(st, samples[i]);
    final hi = _encodeSample(st, samples[i + 1]);
    out.add(lo | (hi << 4));
  }
  return bytes(out);
}

/// Cases: shared/fixtures/adpcm.json (see shared/fixtures/README.md).
void main() {
  final fixture = loadFixture('adpcm');

  test('tables and gap limit', () {
    expect(adpcmStepTable, fixture['stepTable']);
    expect(_indexTable, fixture['indexTable']);
    expect(ADPCMDecoder.maxGapPackets, fixture['maxGapPackets']);
  });

  for (final c in casesOf(fixture, 'sequences')) {
    test(c['name'] as String, () {
      final d = ADPCMDecoder();
      for (final (i, step) in casesOf(c, 'steps').indexed) {
        if (step['reset'] == true) {
          d.reset();
          continue;
        }
        expect(d.decode(bytes(bytesOf(step['packet'] as String))), step['expected'], reason: 'step $i');
      }
    });
  }

  // Not fixture-driven: proves the fixture's encoder vector is what the
  // firmware encoder (in Dart above) produces.
  test('the encoder vector in the fixture comes from the firmware encoder', () {
    final samples = [
      for (var i = 0; i < 160; i++)
        (8000 * (i % 40 < 20 ? 1 : -1) * (i % 7) / 7).round(),
    ];
    final vector = casesOf(fixture, 'sequences').singleWhere(
      (c) => c['name'] == 'decodes exactly what the firmware encoder reconstructs',
    );
    final steps = casesOf(vector, 'steps');
    final st = [0, 0];
    for (var p = 0; p < 4; p++) {
      final chunk = samples.sublist(p * 40, p * 40 + 40);
      final packet = encodePacket(p, chunk, predictor: st[0], index: st[1]);
      expect(hexOf(packet), steps[p]['packet']);
      final expected = <int>[];
      for (final s in chunk) {
        _encodeSample(st, s);
        expected.add(st[0]);
      }
      expect(steps[p]['expected'], expected);
    }
  });
}
