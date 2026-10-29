// Port of app/test/board/protocol_test.dart. Cases: shared/fixtures/protocol.json.
import {
  TextKind,
  boardAudioUuid,
  boardControlUuid,
  boardInfoUuid,
  boardServiceUuid,
  boardTextUuid,
  frameText,
  graphemes,
  labelText,
  maxLabelBytes,
  maxTextBytes,
  parseBoardInfo,
  textKindCodes,
  textKinds,
  timeFrame,
  timeText,
  utf8Encode,
} from '../src/board/protocol';
import {JsonObject, bytesOf, casesOf, hexOf, loadFixture} from './fixtures';

const fixture = loadFixture('protocol');

test('uuids', () => {
  const u = fixture.uuids as JsonObject;
  expect(boardServiceUuid).toBe(u.service);
  expect(boardAudioUuid).toBe(u.audio);
  expect(boardTextUuid).toBe(u.text);
  expect(boardControlUuid).toBe(u.control);
  expect(boardInfoUuid).toBe(u.info);
});

test('TextKind codes and limits', () => {
  expect(Object.fromEntries(textKinds.map(k => [k, textKindCodes[k]]))).toEqual(
    fixture.textKinds,
  );
  expect(maxTextBytes).toBe(fixture.maxTextBytes);
  expect(maxLabelBytes).toBe(fixture.maxLabelBytes);
});

describe('frameText', () => {
  for (const c of casesOf(fixture, 'frameText')) {
    test(c.name as string, () => {
      const f = frameText(c.text as string, c.kind as TextKind, c.maxWrite as number);
      expect(f.map(hexOf)).toEqual(c.expected);
    });
  }
});

describe('labelText', () => {
  for (const c of casesOf(fixture, 'labelText')) {
    test(c.name as string, () => {
      expect(labelText(c.input as string)).toBe(c.expected);
    });
  }
});

// The board text never uses Intl.Segmenter (its answer depends on the engine's Unicode version);
// where the engine has one, it is an oracle for the fixture strings.
type Segmenter = {segment(text: string): Iterable<{segment: string}>};
const SegmenterCtor = (
  Intl as unknown as {
    Segmenter?: new (l?: string, o?: {granularity: 'grapheme'}) => Segmenter;
  }
).Segmenter;
const testWithSegmenter = SegmenterCtor ? test : test.skip;

testWithSegmenter('graphemes equal Intl.Segmenter on every fixture string', () => {
  const seg = new (SegmenterCtor as NonNullable<typeof SegmenterCtor>)(undefined, {
    granularity: 'grapheme',
  });
  const strings = [
    ...casesOf(fixture, 'frameText').map(c => c.text as string),
    ...casesOf(fixture, 'labelText').map(c => c.input as string),
    // Samples of the scripts the app meets (none uses a post-15.1 conjunct linker).
    'Xin chào, hôm nay trời đẹp quá. Tiếng Việt',
    'こんにちは、世界。カタカナ ｶﾀｶﾅ',
    '안녕하세요 각 각',
    'สวัสดีครับ น้ำ กำลัง',
    'ສະບາຍດີ ນ້ຳ',
    'नमस्ते दुनिया, क्षत्रिय श्रीमान',
    'আমি বাংলায় কথা বলি ক্ষ',
    'தமிழ் ஸ்ரீ',
    'Привет, мир! Ελληνικά',
    'مرحبا بالعالم',
    '👍🏽 👩‍💻 🇻🇳🇯🇵 ❤️ 1️⃣',
    'a\r\nb\tc­d',
  ];
  for (const s of strings) {
    expect(graphemes(s)).toEqual(Array.from(seg.segment(s), x => x.segment));
  }
});

test('graphemes do not depend on Intl.Segmenter', () => {
  const intl = Intl as unknown as {Segmenter?: unknown};
  const saved = intl.Segmenter;
  delete intl.Segmenter;
  try {
    jest.isolateModules(() => {
      const p = require('../src/board/protocol') as typeof import('../src/board/protocol');
      for (const c of casesOf(fixture, 'labelText')) {
        expect(p.labelText(c.input as string)).toBe(c.expected);
      }
      for (const c of casesOf(fixture, 'frameText')) {
        const f = p.frameText(c.text as string, c.kind as TextKind, c.maxWrite as number);
        expect(f.map(hexOf)).toEqual(c.expected);
      }
    });
  } finally {
    intl.Segmenter = saved;
  }
});

describe('graphemes (UAX #29 with the Unicode 15.1 conjunct linkers)', () => {
  test('marks, emoji sequences, flags, CR LF and controls', () => {
    expect(graphemes('éa')).toEqual(['é', 'a']);
    expect(graphemes('\u{1F44D}\u{1F3FD}x')).toEqual(['\u{1F44D}\u{1F3FD}', 'x']);
    expect(graphemes('\u{1F469}‍\u{1F4BB}!')).toEqual(['\u{1F469}‍\u{1F4BB}', '!']);
    expect(graphemes('\u{1F1FB}\u{1F1F3}\u{1F1EF}\u{1F1F5}')).toEqual([
      '\u{1F1FB}\u{1F1F3}',
      '\u{1F1EF}\u{1F1F5}',
    ]);
    expect(graphemes('\r\nb')).toEqual(['\r\n', 'b']);
    expect(graphemes('a\u0000́b')).toEqual(['a', '\u0000', '́', 'b']);
    expect(graphemes('')).toEqual([]);
  });

  test('Thai and Lao AM extend', () => {
    expect(graphemes('กำา')).toEqual(['กำ', 'า']);
    expect(graphemes('ສຳ')).toEqual(['ສຳ']);
  });

  test('conjuncts of the Unicode 15.1 linker scripts', () => {
    expect(graphemes('नमस्ते')).toEqual(['न', 'म', 'स्ते']);
    expect(graphemes('क्षत्रिय')).toEqual(['क्ष', 'त्रि', 'य']);
    // Bengali, Gujarati, Oriya, Telugu, Malayalam: consonant + virama + consonant.
    for (const [c, v] of [
      [0x995, 0x9cd],
      [0xa95, 0xacd],
      [0xb15, 0xb4d],
      [0xc15, 0xc4d],
      [0xd15, 0xd4d],
    ]) {
      const s = String.fromCodePoint(c, v, c);
      expect(graphemes(s)).toEqual([s]);
    }
    // A virama before a non-consonant (independent vowel) does not join.
    expect(graphemes('स्अ')).toEqual(['स्', 'अ']);
    // Khmer coeng is not a 15.1 linker (Dart and Swift split it too).
    expect(graphemes('ក្យ')).toEqual(['ក្', 'យ']);
  });

  test('Hangul jamo L/V/T/LV/LVT', () => {
    expect(graphemes('ᄀᄀ하')).toEqual(['ᄀᄀ하']); // L L LVT
    expect(graphemes('각')).toEqual(['각']); // L V T
    expect(graphemes('가ᅡᆨ')).toEqual(['가ᅡᆨ']); // LV V T
    expect(graphemes('각ᆨᅡ')).toEqual(['각ᆨ', 'ᅡ']); // LVT T | V
    expect(graphemes('가가')).toEqual(['가', '가']);
    expect(graphemes('aᅡ')).toEqual(['a', 'ᅡ']);
  });

  test('a cut never splits a combining sequence', () => {
    // 50 × "ệ" decomposed (e + U+0323 + U+0302 = 5 UTF-8 bytes): the tail is cut between clusters.
    const text = 'ệ'.repeat(50);
    const payload = frameText(text, 'subtitle', 512)[0].subarray(2);
    const body = new TextDecoder().decode(payload).slice(1); // after "…"
    expect(body).toBe('ệ'.repeat(30));
  });
});

test('utf8Encode equals the platform encoder', () => {
  for (const s of ['', 'abc', 'Xin chào', '日本語', '😀 é', '\u0000߿ࠀ￿']) {
    expect(Array.from(utf8Encode(s))).toEqual(Array.from(new TextEncoder().encode(s)));
  }
});

describe('parseBoardInfo', () => {
  for (const c of casesOf(fixture, 'boardInfo')) {
    test(c.name as string, () => {
      const info = parseBoardInfo(bytesOf(c.hex as string));
      const want = c.expected as JsonObject | null;
      if (want === null) {
        expect(info).toBeNull();
      } else {
        expect(info?.protocolVersion).toBe(want.protocolVersion);
        expect(info?.fontSets.value).toBe(want.fontSets);
      }
    });
  }
});

describe('time', () => {
  for (const c of casesOf(fixture, 'timeText')) {
    test(c.name as string, () => {
      expect(timeText(new Date(c.epochMs as number), c.utcOffsetMinutes as number)).toBe(
        c.expected,
      );
    });
  }

  test('other offsets and instants before 1970', () => {
    expect(timeText(new Date(1761400000999), 420)).toBe('1761400000 420');
    expect(timeText(new Date(1761400000000), -150)).toBe('1761400000 -150');
    expect(timeText(new Date(-1), 0)).toBe('-1 0');
  });

  test('timeFrame is one kind-2 chunk in local time', () => {
    const t = new Date(1761400000000);
    const frame = timeFrame(t);
    expect(Array.from(frame.subarray(0, 2))).toEqual([0x03, 2]);
    const text = new TextDecoder().decode(frame.subarray(2));
    expect(text).toBe(timeText(t));
    expect(text).toBe(`1761400000 ${-t.getTimezoneOffset()}`);
  });
});
