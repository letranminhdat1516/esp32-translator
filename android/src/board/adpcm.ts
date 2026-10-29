/* eslint-disable no-bitwise -- byte-level ADPCM decoding */
// Port of app/lib/board/adpcm.dart. Contract: shared/fixtures/adpcm.json.

/** IMA ADPCM index adjustment per 4-bit code (same table as firmware/main/adpcm.c). */
export const adpcmIndexTable: readonly number[] = [
  -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
];

/** IMA ADPCM step sizes (same table as firmware/main/adpcm.c). */
export const adpcmStepTable: readonly number[] = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
  12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
];

const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v);

/**
 * Decodes IMA ADPCM packets from the board:
 * `[seq u16][predictor i16][index u8][data, low nibble first]` (little endian). Every packet
 * carries its own state, so a lost packet only needs matching silence inserted.
 */
export class ADPCMDecoder {
  static readonly maxGapPackets = 10;

  private lastSeq: number | null = null;

  /**
   * Decodes one packet to 16-bit samples. A packet with no data (header only or shorter)
   * decodes to nothing. When 1..maxGapPackets packets were lost since the previous one, the
   * same number of packets of silence precedes the samples.
   */
  decode(packet: Uint8Array): Int16Array {
    if (packet.length <= 5) {
      return new Int16Array(0);
    }
    const seq = packet[0] | (packet[1] << 8);
    let predictor = ((packet[2] | (packet[3] << 8)) << 16) >> 16; // signed 16-bit
    // Swift traps on an index above 88; a corrupt header must not crash here.
    let index = packet[4] > 88 ? 88 : packet[4];
    const samplesPerPacket = (packet.length - 5) * 2;

    let silence = 0;
    if (this.lastSeq !== null) {
      const gap = ((seq - this.lastSeq) & 0xffff) - 1;
      if (gap > 0 && gap <= ADPCMDecoder.maxGapPackets) {
        silence = gap * samplesPerPacket;
      }
    }
    this.lastSeq = seq;

    const out = new Int16Array(silence + samplesPerPacket);
    let o = silence;
    // One IMA ADPCM step: updates predictor and index, returns the sample.
    const decodeNibble = (code: number): number => {
      const step = adpcmStepTable[index];
      let delta = step >> 3;
      if (code & 4) {
        delta += step;
      }
      if (code & 2) {
        delta += step >> 1;
      }
      if (code & 1) {
        delta += step >> 2;
      }
      predictor = clamp(predictor + (code & 8 ? -delta : delta), -32768, 32767);
      index = clamp(index + adpcmIndexTable[code], 0, 88);
      return predictor;
    };
    for (let i = 5; i < packet.length; i++) {
      const byte = packet[i];
      out[o++] = decodeNibble(byte & 0x0f); // low nibble first
      out[o++] = decodeNibble(byte >> 4);
    }
    return out;
  }

  /** Forgets the last sequence number (no silence before the next packet). */
  reset(): void {
    this.lastSeq = null;
  }
}
