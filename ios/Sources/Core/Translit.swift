import Foundation

// Port of app/lib/core/translit.dart. The tables are the export in shared/fixtures/translit.json (the Dart file is the
// source of truth); TranslitTableTests fails if they differ.

/// Transliteration tables for the board, which can only draw the scripts whose font sets it reports: Cyrillic and
/// Greek always come out in Latin letters; Japanese kana does when the board has no CJK font. Han, Hangul, Thai and
/// the rest have no table.
enum Translit {
    // MARK: Cyrillic

    /// Lower-case Cyrillic letter → Latin (simplified BGN/PCGN; Russian, Ukrainian, Belarusian, Bulgarian, Serbian,
    /// Macedonian and Kazakh letters).
    static let cyrillic: [Unicode.Scalar: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // Ukrainian, Belarusian
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
        // Serbian, Macedonian
        "ј": "j", "љ": "lj", "њ": "nj", "ћ": "c", "ђ": "dj", "џ": "dz",
        "ѓ": "g", "ќ": "k", "ѕ": "dz",
        // Kazakh and other Central Asian letters
        "ә": "a", "ғ": "gh", "қ": "q", "ң": "ng", "ө": "o", "ұ": "u", "ү": "u",
        "һ": "h",
    ]

    // MARK: Greek

    /// Lower-case Greek letter → Latin (simplified ELOT 743, modern pronunciation).
    static let greek: [Unicode.Scalar: String] = [
        "α": "a", "β": "v", "γ": "g", "δ": "d", "ε": "e", "ζ": "z", "η": "i",
        "θ": "th", "ι": "i", "κ": "k", "λ": "l", "μ": "m", "ν": "n", "ξ": "x",
        "ο": "o", "π": "p", "ρ": "r", "σ": "s", "ς": "s", "τ": "t", "υ": "y",
        "φ": "f", "χ": "ch", "ψ": "ps", "ω": "o",
        // with tonos / dialytika
        "ά": "a", "έ": "e", "ή": "i", "ί": "i", "ό": "o", "ύ": "y", "ώ": "o",
        "ϊ": "i", "ΐ": "i", "ϋ": "y", "ΰ": "y",
    ]

    /// The single lower-case scalar of `s`, or nil when lower-casing gives several.
    private static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        let l = String(s).lowercased().unicodeScalars
        return l.count == 1 ? l.first : nil
    }

    /// True for a letter `letter(_:)` can turn into Latin.
    static func hasLetterTable(_ s: Unicode.Scalar) -> Bool { letter(s) != nil }

    /// Latin spelling of a Cyrillic or Greek letter, or nil for any other character. A capital gives a capital first
    /// letter (`Ж` → `Zh`), or the whole spelling in capitals when `allCaps` (the word is all capitals).
    /// `afterOmicron` spells upsilon as `u` (the diphthong `ου`).
    static func letter(_ s: Unicode.Scalar, allCaps: Bool = false, afterOmicron: Bool = false) -> String? {
        guard let lower = lower(s), var latin = cyrillic[lower] ?? greek[lower] else { return nil }
        if afterOmicron && (lower == "υ" || lower == "ύ") { latin = "u" }
        if lower == s || latin.isEmpty { return latin }
        return allCaps ? latin.uppercased() : latin.prefix(1).uppercased() + latin.dropFirst()
    }

    /// True for Greek omicron, either case, with or without tonos.
    static func isOmicron(_ s: Unicode.Scalar) -> Bool {
        let l = lower(s)
        return l == "ο" || l == "ό"
    }

    // MARK: Latin letters outside the board's range

    /// Letters with no canonical decomposition, spelled with plain ASCII.
    static let latinSpecialTable: [Unicode.Scalar: String] = [
        "ł": "l", "Ł": "L", "ø": "o", "Ø": "O", "ß": "ss", "ẞ": "SS", "æ": "ae",
        "Æ": "AE", "œ": "oe", "Œ": "OE", "ħ": "h", "Ħ": "H", "ŧ": "t", "Ŧ": "T",
        "ı": "i", "đ": "d", "Đ": "D", "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th",
        "ŋ": "ng", "Ŋ": "Ng", "ĸ": "k", "ſ": "s",
    ]

    /// ASCII spelling of a Latin letter the board cannot draw, or nil.
    static func latinSpecial(_ s: Unicode.Scalar) -> String? { latinSpecialTable[s] }

    // MARK: Punctuation and symbols

    /// Characters the board cannot draw, spelled with ones it can. A space means "separate the words".
    static let punctuation: [Unicode.Scalar: String] = [
        "‐": "-", "‑": "-", "‒": "-", "―": "-", "−": "-",
        "‚": ",", "„": "\"", "‹": "<", "›": ">", "′": "'",
        "″": "\"", "•": "-", "‧": "-", "⁃": "-",
        "←": "<-", "→": "->", "⇒": "=>",
        "€": "EUR", "₫": "VND", "™": "TM", "‰": "%o",
        // CJK punctuation
        "、": ", ", "。": ". ", "「": "\"", "」": "\"", "『": "\"",
        "』": "\"", "【": "[", "】": "]", "〈": "<", "〉": ">",
        "《": "<", "》": ">", "・": " ", "〜": "~", "\u{3000}": " ",
    ]

    // MARK: Digits of other scripts

    /// Zero of each other script whose digits become ASCII (Arabic-Indic, Extended Arabic-Indic, Devanagari, Bengali,
    /// Thai); its 1–9 follow it.
    static let digitZeros: [UInt32] = [0x0660, 0x06F0, 0x0966, 0x09E6, 0x0E50]

    /// ASCII digit for a decimal digit of another script, or nil.
    static func asciiDigit(_ s: Unicode.Scalar) -> String? {
        for zero in digitZeros where s.value >= zero && s.value <= zero + 9 {
            return String(UnicodeScalar(UInt8(0x30 + s.value - zero)))
        }
        return nil
    }

    // MARK: Japanese kana → romaji (Hepburn)

    static let hiragana: [Unicode.Scalar: String] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
        "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
        "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
        "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
        "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
        "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
        "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
        "や": "ya", "ゆ": "yu", "よ": "yo",
        "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
        "わ": "wa", "ゐ": "i", "ゑ": "e", "を": "o",
        "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
        "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
        "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
        "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
        "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゔ": "vu",
    ]

    static let smallY: [Unicode.Scalar: String] = ["ゃ": "a", "ゅ": "u", "ょ": "o"]
    static let hiraganaRange: ClosedRange<UInt32> = 0x3041...0x3096
    static let katakanaRange: ClosedRange<UInt32> = 0x30A1...0x30F6
    /// Katakana in `katakanaRange` reads as the hiragana this far below it.
    static let katakanaOffset: UInt32 = 0x60
    /// Doubles the next consonant.
    static let sokuon: Unicode.Scalar = "っ"
    static let n: Unicode.Scalar = "ん"
    /// `ん` before these (as hiragana) is written `n'`.
    static let nApostropheBefore: Set<Unicode.Scalar> = ["あ", "い", "う", "え", "お", "や", "ゆ", "よ"]
    /// The long-vowel mark and the iteration marks: nothing on the board.
    static let silent: Set<Unicode.Scalar> = ["ー", "ゝ", "ゞ", "ヽ", "ヾ"]
    /// Hiragana, katakana, the long-vowel mark and the iteration marks.
    static let kanaRanges: [ClosedRange<UInt32>] = [0x3041...0x3096, 0x309D...0x309E, 0x30A1...0x30FA, 0x30FC...0x30FE]

    /// Hiragana for a kana code point (katakana maps onto hiragana by a fixed offset), or nil.
    private static func toHiragana(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        if hiraganaRange.contains(s.value) { return s }
        if katakanaRange.contains(s.value) { return Unicode.Scalar(s.value - katakanaOffset) }
        return nil
    }

    static func isKana(_ s: Unicode.Scalar) -> Bool { kanaRanges.contains { $0.contains(s.value) } }

    /// Reads the kana (plus any small kana that joins it) at `i` in `scalars`. Returns the romaji and how many code
    /// points it used, or nil when `scalars` holds no readable kana there.
    static func readKana(_ scalars: [Unicode.Scalar], _ i: Int) -> (romaji: String, count: Int)? {
        let s = scalars[i]
        if silent.contains(s) { return ("", 1) }
        guard let c = toHiragana(s) else { return nil }
        if c == sokuon {
            guard i + 1 < scalars.count, let next = readKana(scalars, i + 1), let first = next.romaji.first else {
                return ("", 1)
            }
            if "aiueon".contains(first) { return (next.romaji, 1 + next.count) }
            let doubled = next.romaji.hasPrefix("ch") ? "t" : String(first)
            return (doubled + next.romaji, 1 + next.count)
        }
        if c == n {
            let next = i + 1 < scalars.count ? toHiragana(scalars[i + 1]) : nil
            return (next.map(nApostropheBefore.contains) == true ? "n'" : "n", 1)
        }
        if let vowel = smallY[c] { return ("y" + vowel, 1) }
        guard let base = hiragana[c] else { return nil }
        if i + 1 < scalars.count, base.count >= 2, base.hasSuffix("i"),
           let next = toHiragana(scalars[i + 1]), let small = smallY[next] {
            let stem = String(base.dropLast())
            let combined = ["sh", "ch", "j"].contains(stem) ? stem + small : stem + "y" + small
            return (combined, 2)
        }
        return (base, 1)
    }
}
