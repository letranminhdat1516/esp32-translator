import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../core/model.dart';

/// GATT identifiers of the subtitle board. Byte-compatible with the firmware
/// and with ios/Sources/BLE/ESPLink.swift.
const boardServiceUuid = 'A7C00001-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/// Notify: audio packets from the board mic.
const boardAudioUuid = 'A7C00002-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/// Write: text chunks `[flags][kind][payload]`.
const boardTextUuid = 'A7C00003-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/// Write: mic on/off and keepalive; notify: mic state changes.
const boardControlUuid = 'A7C00004-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/// Read: `[version u8][fontSets u32 LE]`. Absent on older firmware.
const boardInfoUuid = 'A7C00005-3B2F-4C1E-9D8A-5F6E7D8C9B0A';

/// First byte after the flags of a text chunk: what the board does with it.
enum TextKind {
  subtitle(0),
  status(1),
  time(2),
  label(3);

  const TextKind(this.code);
  final int code;
}

/// The round screen shows about 5 lines, so only this many bytes are sent.
const maxTextBytes = 150;

/// Longest label the board accepts (UTF-8 bytes).
const maxLabelBytes = 32;

int _utf8Len(Characters c) => utf8.encode(c.string).length;

/// Mirrors `ESPLink.tail(of:maxBytes:)`: keeps the tail of [text] within
/// [maxTextBytes], never splitting a grapheme cluster, then drops the partial
/// word up to the first space and prefixes "…".
String _tail(String text) {
  if (utf8.encode(text).length <= maxTextBytes) return text;
  var rest = text.characters;
  while (_utf8Len(rest) > maxTextBytes) {
    rest = rest.skip(1);
  }
  final space = rest.toList().indexOf(' ');
  if (space >= 0) rest = rest.skip(space + 1);
  return '…${rest.string}';
}

/// Splits [text] into the chunks written to the text characteristic.
/// Mirrors `ESPLink.send`: [maxWrite] is the peripheral's maximum
/// write-without-response length; the payload per chunk is
/// `max(20, maxWrite) - 2`. Flags: bit0 first chunk, bit1 last chunk. There is
/// always at least one chunk.
List<Uint8List> frameText(String text, TextKind kind, int maxWrite) {
  final payload = utf8.encode(_tail(text));
  final size = (maxWrite < 20 ? 20 : maxWrite) - 2;
  final chunks = <Uint8List>[];
  var offset = 0;
  do {
    final end = offset + size < payload.length ? offset + size : payload.length;
    final flags = (offset == 0 ? 0x01 : 0) | (end == payload.length ? 0x02 : 0);
    chunks.add(
      Uint8List.fromList([flags, kind.code, ...payload.sublist(offset, end)]),
    );
    offset = end;
  } while (offset < payload.length);
  return chunks;
}

/// Payload of the clock message: `"<unix seconds> <UTC offset minutes>"`.
String timeText(DateTime now) {
  final seconds =
      now.millisecondsSinceEpoch ~/ 1000 -
      ((now.millisecondsSinceEpoch % 1000 < 0) ? 1 : 0);
  return '$seconds ${now.timeZoneOffset.inMinutes}';
}

/// The clock message as one chunk (flags 0x03, kind 2), like
/// `ESPLink.timePayload`.
Uint8List timeFrame(DateTime now) => Uint8List.fromList([
  0x03,
  TextKind.time.code,
  ...utf8.encode(timeText(now)),
]);

/// Cuts [label] to at most [maxLabelBytes] UTF-8 bytes at a character
/// boundary, without an ellipsis.
String labelText(String label) {
  var bytes = 0;
  final out = StringBuffer();
  for (final ch in label.characters) {
    final n = utf8.encode(ch).length;
    if (bytes + n > maxLabelBytes) break;
    bytes += n;
    out.write(ch);
  }
  return out.toString();
}

/// Parses the board-info characteristic; null when shorter than 5 bytes.
BoardInfo? parseBoardInfo(Uint8List data) {
  if (data.length < 5) return null;
  final sets = data[1] | data[2] << 8 | data[3] << 16 | data[4] << 24;
  return BoardInfo(protocolVersion: data[0], fontSets: FontSets.fromInt(sets));
}
