/// Transliteration tables for the board, which can only draw the scripts whose
/// font sets it reports: Cyrillic and Greek always come out in Latin letters;
/// Japanese kana does when the board has no CJK font. Han, Hangul, Thai and
/// the rest have no table.
library;

// --- Cyrillic -----------------------------------------------------------

/// Lower-case Cyrillic letter -> Latin (simplified BGN/PCGN; Russian,
/// Ukrainian, Belarusian, Bulgarian, Serbian, Macedonian and Kazakh letters).
const Map<String, String> _cyrillic = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
  'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
  'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch',
  'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
  // Ukrainian, Belarusian
  'і': 'i', 'ї': 'yi', 'є': 'ye', 'ґ': 'g', 'ў': 'u',
  // Serbian, Macedonian
  'ј': 'j', 'љ': 'lj', 'њ': 'nj', 'ћ': 'c', 'ђ': 'dj', 'џ': 'dz',
  'ѓ': 'g', 'ќ': 'k', 'ѕ': 'dz',
  // Kazakh and other Central Asian letters
  'ә': 'a', 'ғ': 'gh', 'қ': 'q', 'ң': 'ng', 'ө': 'o', 'ұ': 'u', 'ү': 'u',
  'һ': 'h',
};

// --- Greek --------------------------------------------------------------

/// Lower-case Greek letter -> Latin (simplified ELOT 743, modern
/// pronunciation).
const Map<String, String> _greek = {
  'α': 'a', 'β': 'v', 'γ': 'g', 'δ': 'd', 'ε': 'e', 'ζ': 'z', 'η': 'i',
  'θ': 'th', 'ι': 'i', 'κ': 'k', 'λ': 'l', 'μ': 'm', 'ν': 'n', 'ξ': 'x',
  'ο': 'o', 'π': 'p', 'ρ': 'r', 'σ': 's', 'ς': 's', 'τ': 't', 'υ': 'y',
  'φ': 'f', 'χ': 'ch', 'ψ': 'ps', 'ω': 'o',
  // with tonos / dialytika
  'ά': 'a', 'έ': 'e', 'ή': 'i', 'ί': 'i', 'ό': 'o', 'ύ': 'y', 'ώ': 'o',
  'ϊ': 'i', 'ΐ': 'i', 'ϋ': 'y', 'ΰ': 'y',
};

/// True for a letter [translitLetter] can turn into Latin.
bool hasLetterTable(int cp) => translitLetter(cp) != null;

/// Latin spelling of a Cyrillic or Greek letter, or null for any other
/// character. A capital gives a capital first letter (`Ж` -> `Zh`), or the
/// whole spelling in capitals when [allCaps] (the word is all capitals).
/// [afterOmicron] spells upsilon as `u` (the diphthong `ου`).
String? translitLetter(int cp, {bool allCaps = false, bool afterOmicron = false}) {
  final ch = String.fromCharCode(cp);
  final lower = ch.toLowerCase();
  final isUpper = lower != ch;
  var latin = _cyrillic[lower] ?? _greek[lower];
  if (latin == null) return null;
  if (afterOmicron && (lower == 'υ' || lower == 'ύ')) latin = 'u';
  if (!isUpper || latin.isEmpty) return latin;
  return allCaps ? latin.toUpperCase() : latin[0].toUpperCase() + latin.substring(1);
}

/// True for Greek lower-case omicron, with or without tonos.
bool isOmicron(int cp) {
  final lower = String.fromCharCode(cp).toLowerCase();
  return lower == 'ο' || lower == 'ό';
}

// --- Latin letters outside the board's range ----------------------------

/// Letters with no canonical decomposition, spelled with plain ASCII.
const Map<String, String> _latinSpecial = {
  'ł': 'l', 'Ł': 'L', 'ø': 'o', 'Ø': 'O', 'ß': 'ss', 'ẞ': 'SS', 'æ': 'ae',
  'Æ': 'AE', 'œ': 'oe', 'Œ': 'OE', 'ħ': 'h', 'Ħ': 'H', 'ŧ': 't', 'Ŧ': 'T',
  'ı': 'i', 'đ': 'd', 'Đ': 'D', 'ð': 'd', 'Ð': 'D', 'þ': 'th', 'Þ': 'Th',
  'ŋ': 'ng', 'Ŋ': 'Ng', 'ĸ': 'k', 'ſ': 's',
};

/// ASCII spelling of a Latin letter the board cannot draw, or null.
String? latinSpecial(String char) => _latinSpecial[char];

// --- Punctuation and symbols --------------------------------------------

/// Characters the board cannot draw, spelled with ones it can. A space means
/// "separate the words".
const Map<String, String> punctuation = {
  '‐': '-', '‑': '-', '‒': '-', '―': '-', '−': '-',
  '‚': ',', '„': '"', '‹': '<', '›': '>', '′': "'",
  '″': '"', '•': '-', '‧': '-', '⁃': '-',
  '←': '<-', '→': '->', '⇒': '=>',
  '€': 'EUR', '₫': 'VND', '™': 'TM', '‰': '%o',
  // CJK punctuation
  '、': ', ', '。': '. ', '「': '"', '」': '"', '『': '"',
  '』': '"', '【': '[', '】': ']', '〈': '<', '〉': '>',
  '《': '<', '》': '>', '・': ' ', '〜': '~', '\u3000': ' ',
};

// --- Digits of other scripts ---------------------------------------------

/// ASCII digit for a decimal digit of another script, or null.
String? asciiDigit(int cp) {
  const zeros = [0x0660, 0x06f0, 0x0966, 0x09e6, 0x0e50];
  for (final zero in zeros) {
    if (cp >= zero && cp <= zero + 9) return String.fromCharCode(0x30 + cp - zero);
  }
  return null;
}

// --- Japanese kana -> romaji (Hepburn) ----------------------------------

const Map<String, String> _hiragana = {
  'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
  'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
  'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
  'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
  'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
  'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
  'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
  'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
  'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
  'わ': 'wa', 'ゐ': 'i', 'ゑ': 'e', 'を': 'o',
  'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
  'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
  'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
  'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
  'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
  'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o', 'ゔ': 'vu',
};

const Map<String, String> _smallY = {'ゃ': 'a', 'ゅ': 'u', 'ょ': 'o'};

/// Hiragana for a kana code point (katakana maps onto hiragana by a fixed
/// offset), or null.
String? _toHiragana(int cp) {
  if (cp >= 0x3041 && cp <= 0x3096) return String.fromCharCode(cp);
  if (cp >= 0x30a1 && cp <= 0x30f6) return String.fromCharCode(cp - 0x60);
  if (cp == 0x30f4) return 'ゔ';
  return null;
}

/// True for hiragana, katakana, the long-vowel mark and the iteration marks.
bool isKana(int cp) =>
    (cp >= 0x3041 && cp <= 0x3096) ||
    (cp >= 0x30a1 && cp <= 0x30fa) ||
    cp == 0x30fc ||
    cp == 0x309d ||
    cp == 0x309e ||
    cp == 0x30fd ||
    cp == 0x30fe;

const _vowelKana = {'あ', 'い', 'う', 'え', 'お', 'や', 'ゆ', 'よ'};

/// Reads the kana (plus any small kana that joins it) at [i] in [runes].
/// Returns the romaji and how many code points it used, or null when
/// [runes] holds no kana there.
(String, int)? readKana(List<int> runes, int i) {
  final cp = runes[i];
  if (cp == 0x30fc) return ('', 1); // long vowel mark: not drawable
  if (cp == 0x309d || cp == 0x309e || cp == 0x30fd || cp == 0x30fe) return ('', 1);
  final c = _toHiragana(cp);
  if (c == null) return null;
  if (c == 'っ') {
    // doubles the next consonant
    final next = i + 1 < runes.length ? readKana(runes, i + 1) : null;
    if (next == null || next.$1.isEmpty) return ('', 1);
    final first = next.$1[0];
    if ('aiueon'.contains(first)) return (next.$1, 1 + next.$2);
    final doubled = next.$1.startsWith('ch') ? 't' : first;
    return ('$doubled${next.$1}', 1 + next.$2);
  }
  if (c == 'ん') {
    final next = i + 1 < runes.length ? _toHiragana(runes[i + 1]) : null;
    return (next != null && _vowelKana.contains(next) ? "n'" : 'n', 1);
  }
  if (_smallY.containsKey(c)) return ('y${_smallY[c]}', 1);
  final base = _hiragana[c];
  if (base == null) return null;
  if (i + 1 < runes.length && base.length >= 2 && base.endsWith('i')) {
    final small = _smallY[_toHiragana(runes[i + 1]) ?? ''];
    if (small != null) {
      final stem = base.substring(0, base.length - 1);
      final combined = switch (stem) {
        'sh' || 'ch' || 'j' => '$stem$small',
        _ => '${stem}y$small',
      };
      return (combined, 2);
    }
  }
  return (base, 1);
}
