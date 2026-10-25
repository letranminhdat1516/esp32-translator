import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_translator/board/adpcm.dart';

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

void main() {
  test('decodes the shared vector', () {
    final d = ADPCMDecoder();
    expect(d.decode(bytes([0, 0, 0, 0, 0, 0x07])), [11, 13]);
  });

  test('fills small gaps with silence', () {
    final d = ADPCMDecoder();
    d.decode(bytes([0, 0, 0, 0, 0, 0x07]));
    // seq 1 and 2 lost: 2 packets x 2 samples of silence
    final next = d.decode(bytes([3, 0, 0, 0, 0, 0x07]));
    expect(next, [0, 0, 0, 0, 11, 13]);
    d.reset();
    // after reset: no gap fill
    expect(d.decode(bytes([9, 0, 0, 0, 0, 0x07])), [11, 13]);
    // shorter than a header: nothing
    expect(d.decode(bytes([1, 2, 3])), isEmpty);
  });

  test('a packet with only a header decodes to nothing', () {
    final d = ADPCMDecoder();
    expect(d.decode(bytes([0, 0, 0, 0, 0])), isEmpty);
  });

  test('a gap of 10 packets is filled, 11 is not', () {
    final d = ADPCMDecoder();
    d.decode(bytes([0, 0, 0, 0, 0, 0x07]));
    // seq 11: packets 1..10 lost
    expect(d.decode(bytes([11, 0, 0, 0, 0, 0x07])).length, 10 * 2 + 2);
    // seq 23: packets 12..22 lost (11): too long a gap, no silence
    expect(d.decode(bytes([23, 0, 0, 0, 0, 0x07])), [11, 13]);
  });

  test('the sequence number wraps at 16 bits', () {
    final d = ADPCMDecoder();
    d.decode(bytes([0xff, 0xff, 0, 0, 0, 0x07]));
    // seq 0 follows 65535: nothing lost
    expect(d.decode(bytes([0, 0, 0, 0, 0, 0x07])), [11, 13]);
    // seq 2 after 0: one packet lost
    expect(d.decode(bytes([2, 0, 0, 0, 0, 0x07])).length, 4);
  });

  test('silence matches the packet size', () {
    final d = ADPCMDecoder();
    d.decode(bytes([0, 0, 0, 0, 0, 0x07, 0x07, 0x07]));
    final next = d.decode(bytes([2, 0, 0, 0, 0, 0x07, 0x07, 0x07]));
    expect(next.sublist(0, 6), List.filled(6, 0));
    expect(next.length, 6 + 6);
  });

  test('every packet carries its own predictor and index', () {
    final d = ADPCMDecoder();
    // predictor 1000 (0x03e8), index 20, code 0 => step 50 >> 3 = 6, then index 19: step 45 >> 3 = 5
    final out = d.decode(bytes([0, 0, 0xe8, 0x03, 20, 0x00]));
    expect(out, [1006, 1011]);
    // negative predictor -2: 0xfffe
    final neg = d.decode(bytes([1, 0, 0xfe, 0xff, 0, 0x00]));
    expect(neg, [-2 + 0, -2 + 0]);
  });

  test('decodes exactly what the firmware encoder reconstructs', () {
    final samples = [
      for (var i = 0; i < 160; i++)
        (8000 * (i % 40 < 20 ? 1 : -1) * (i % 7) / 7).round(),
    ];
    final d = ADPCMDecoder();
    final st = [0, 0];
    for (var p = 0; p < 4; p++) {
      final chunk = samples.sublist(p * 40, p * 40 + 40);
      final packet = encodePacket(p, chunk, predictor: st[0], index: st[1]);
      // The encoder's state after each sample is what a decoder must produce.
      final expected = <int>[];
      for (final s in chunk) {
        _encodeSample(st, s);
        expected.add(st[0]);
      }
      expect(d.decode(packet), expected);
    }
  });

  test('clamps the predictor and ignores an out-of-range index', () {
    final d = ADPCMDecoder();
    // index 200 would run off the step table: treated as 88
    final out = d.decode(bytes([0, 0, 0xff, 0x7f, 200, 0x07, 0x77]));
    expect(out.length, 4);
    expect(out.every((s) => s <= 32767 && s >= -32768), isTrue);
    expect(out.last, 32767);
  });
}
