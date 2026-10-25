import 'dart:typed_data';

const List<int> _indexTable = [
  -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8, //
];

/// IMA ADPCM step sizes (same table as firmware/main/adpcm.c).
const List<int> adpcmStepTable = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, //
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
  12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

/// Decodes IMA ADPCM packets from the board:
/// `[seq u16][predictor i16][index u8][data, low nibble first]` (little
/// endian). Every packet carries its own state, so a lost packet only needs
/// matching silence inserted.
class ADPCMDecoder {
  static const int maxGapPackets = 10;

  int? _lastSeq;

  /// Decodes one packet to 16-bit samples. A packet with no data (header only
  /// or shorter) decodes to nothing. When 1..[maxGapPackets] packets were lost
  /// since the previous one, the same number of packets of silence precedes
  /// the samples.
  Int16List decode(Uint8List packet) {
    if (packet.length <= 5) return Int16List(0);
    final seq = packet[0] | (packet[1] << 8);
    var predictor = (packet[2] | (packet[3] << 8)).toSigned(16);
    // Swift traps on an index above 88; a corrupt header must not crash here.
    var index = packet[4] > 88 ? 88 : packet[4];
    final samplesPerPacket = (packet.length - 5) * 2;

    var silence = 0;
    final last = _lastSeq;
    if (last != null) {
      final gap = ((seq - last) & 0xffff) - 1;
      if (gap > 0 && gap <= maxGapPackets) silence = gap * samplesPerPacket;
    }
    _lastSeq = seq;

    final out = Int16List(silence + samplesPerPacket);
    var o = silence;
    for (var i = 5; i < packet.length; i++) {
      final byte = packet[i];
      for (final code in [byte & 0x0f, byte >> 4]) {
        final step = adpcmStepTable[index];
        var delta = step >> 3;
        if (code & 4 != 0) delta += step;
        if (code & 2 != 0) delta += step >> 1;
        if (code & 1 != 0) delta += step >> 2;
        predictor += (code & 8 != 0) ? -delta : delta;
        predictor = predictor.clamp(-32768, 32767);
        index = (index + _indexTable[code]).clamp(0, 88);
        out[o++] = predictor;
      }
    }
    return out;
  }

  void reset() => _lastSeq = null;
}
