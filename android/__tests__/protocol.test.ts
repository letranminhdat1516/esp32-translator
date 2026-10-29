// Port of app/test/board/protocol_test.dart. Cases: shared/fixtures/protocol.json.
import {
  TextKind,
  boardAudioUuid,
  boardControlUuid,
  boardInfoUuid,
  boardServiceUuid,
  boardTextUuid,
  defaultGraphemes,
  fallbackGraphemes,
  frameText,
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

// Hermes may lack Intl.Segmenter; the fallback segmentation must pass the same cases.
describe.each([
  ['Intl.Segmenter', undefined],
  ['fallback graphemes', fallbackGraphemes],
])('with %s', (_label, graphemes) => {
  describe('frameText', () => {
    for (const c of casesOf(fixture, 'frameText')) {
      test(c.name as string, () => {
        const f = frameText(c.text as string, c.kind as TextKind, c.maxWrite as number, graphemes);
        expect(f.map(hexOf)).toEqual(c.expected);
      });
    }
  });

  describe('labelText', () => {
    for (const c of casesOf(fixture, 'labelText')) {
      test(c.name as string, () => {
        expect(labelText(c.input as string, graphemes)).toBe(c.expected);
      });
    }
  });
});

describe('fallback graphemes', () => {
  test('Node has Intl.Segmenter, so both paths above ran', () => {
    expect(defaultGraphemes).not.toBe(fallbackGraphemes);
  });

  test('keeps marks, emoji sequences and flags together', () => {
    expect(fallbackGraphemes('éa')).toEqual(['é', 'a']);
    expect(fallbackGraphemes('👍🏽x')).toEqual(['👍🏽', 'x']);
    expect(fallbackGraphemes('👩‍💻!')).toEqual(['👩‍💻', '!']);
    expect(fallbackGraphemes('🇻🇳🇯🇵')).toEqual(['🇻🇳', '🇯🇵']);
    expect(fallbackGraphemes('\r\nb')).toEqual(['\r\n', 'b']);
    expect(fallbackGraphemes('')).toEqual([]);
  });

  test('a cut never splits a combining sequence', () => {
    // 50 × "ệ" decomposed (e + U+0323 + U+0302 = 5 UTF-8 bytes): the tail is cut between clusters.
    const text = 'ệ'.repeat(50);
    for (const graphemes of [undefined, fallbackGraphemes]) {
      const payload = frameText(text, 'subtitle', 512, graphemes)[0].subarray(2);
      const body = new TextDecoder().decode(payload).slice(1); // after "…"
      expect(body).toBe('ệ'.repeat(30));
    }
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
