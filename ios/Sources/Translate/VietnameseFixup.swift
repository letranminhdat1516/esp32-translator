import Foundation

/// Cheap text fix-ups around the Vietnamese recognizer and the VI→EN translator.
///
/// The Vietnamese dictation model ignores contextual strings and custom language models, so recurring
/// mishearings are fixed after recognition with a small table taken from measured confusions. Vocatives
/// ("em ơi") and some service phrases are rewritten only for the translator, which otherwise renders
/// "Em ơi, tính tiền!" as "Baby, charge!". All rules match whole words only.
enum VietnameseFixup {
    /// Loanwords and brand names the recognizer spells as Vietnamese syllables. Applied to the recognized
    /// text itself (shown and translated).
    static func fixLoanwords(_ text: String) -> String {
        apply(loanwordRules, to: text)
    }

    /// The text given to the VI→EN translator: loanwords fixed, vocatives dropped, service phrases and a
    /// few idioms put in plain Vietnamese. Never shown.
    static func forTranslation(_ text: String) -> String {
        let fixed = apply(loanwordRules, to: text)
        let rewritten = tidy(apply(translationRules, to: fixed), original: text)
        // Only vocatives ("Ông ơi, ông bà ơi"): keep them rather than translate nothing
        return rewritten.contains(where: \.isLetter) ? rewritten : fixed
    }

    // MARK: Rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        /// The rule applies only when the whole text also matches this (context, e.g. talk about a price)
        let context: NSRegularExpression?

        /// `atClauseStart`: the match must begin the text or follow , . ! ? (the template gets the
        /// punctuation back as $1)
        init(_ pattern: String, _ template: String, atClauseStart: Bool = false, context: String? = nil) {
            // Whole words only: no letter or digit may touch the match
            let start = atClauseStart ? "(^|[,.!?])\\s*" : "(?<![\\p{L}\\p{N}])"
            let bounded = "\(start)(?:\(pattern))(?![\\p{L}\\p{N}])"
            regex = try! NSRegularExpression(pattern: bounded, options: [.caseInsensitive])
            self.template = template
            self.context = context.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        }
    }

    /// Observed in the measurement spike (25 sentences × 13 conditions), plus spelling variants
    private static let loanwordRules: [Rule] = [
        Rule("gran(?:t|d)? (?:out|ao)|grab out|gờ ráp|xe ra rounds", "Grab"),
        Rule("(?<=xe )gram", "Grab"),
        Rule("hoa phay|hoa pha(?! lê)|oai phai|quai phai|wai phai|wi fi|wifi", "Wi-Fi"),
        Rule("(?<=mật khẩu )(?:khoai tây|phai)", "Wi-Fi"),
        Rule("(?<=(?:qua|bằng|trên|dùng|có|gửi|nhắn|gọi) )giữa lo(?! (?:lắng|âu|sợ|ngại|xa|liệu|nghĩ))|zalo lo", "Zalo"),
        Rule("china com|(?:c|phi) nga (?:co|to|tho)|(?<=ở )c call|syria tho|xin ga po|xing ga po|sing ga po|singapo", "Singapore"),
        Rule("phây búc|phây bút|phê búc|phết búc|face book", "Facebook"),
        Rule("i meo|i-meo|e mail|e-mail|ê meo", "email"),
        Rule("ô kê|ô-kê|oke|okê|okey", "OK"),
        // "ở" heard as "ngở" after a nasal ending ("ngở" is not a Vietnamese word; "ngở ngàng" is a
        // misspelled "ngỡ ngàng")
        Rule("ngở(?! ngàng)", "ở"),
    ]

    private static let pronoun = "em|anh|chị|cô|chú|bác|ông|bà|bạn|cháu|con|dì|cậu|mợ|thím"
    /// Kinship vocatives, pairs first ("ông bà ơi")
    private static let vocative = "ông bà|cô chú|anh chị|cô bác|chú bác|\(pronoun)"
    /// A number is a price only with a scale word or three digits ("hai cái" is a count), not a year
    private static let priceScale = "trăm|nghìn|ngàn|triệu|rưỡi|chục|k|đồng|\\d+[.,]\\d{3}|(?!(?:19|20)\\d\\d(?!\\d))\\d{3,}"
    /// …and ends the phrase ("hai trăm cái bánh" counts cakes)
    private static let phraseEnd = "(?=\\s*(?:thôi|nhé|nha|đi|ạ|à|[,.!?]|$))"
    private static let numberWord = "\\d[\\d.,]*|một|hai|ba|bốn|tư|năm|lăm|sáu|bảy|tám|chín|mười|mươi|mốt|trăm|nghìn|ngàn|triệu|rưỡi|chục|k"

    private static let translationRules: [Rule] = [
        // Vocatives at the start or end of a clause: "em ơi", "anh ơi", "ông bà ơi", a bare "ơi" (not
        // "trời ơi", "mẹ ơi": exclamations; not "anh ơi là anh")
        Rule("(?:\(vocative)) ơi(?! là)[,!.]?", "$1", atClauseStart: true),
        Rule("ơi[,!.]?", "$1", atClauseStart: true),
        Rule("(?:\(vocative)) ơi(?=\\s*(?:[,.!?]|$))", ""),
        // Asking for the bill: a bare "tính tiền" (not "anh tính tiền đi", "để em tính tiền")
        Rule("tính tiền(?: (?:đi|nhé|nha|ạ|với|(?:giùm|dùm|giúp|cho) (?:\(pronoun)|tôi|mình)|giùm|dùm))*(?=\\s*(?:[,.!?]|$))",
             "$1 cho tôi thanh toán", atClauseStart: true),
        // A seller's "em lấy anh 250 nghìn" is a price, not "I marry you"
        Rule("lấy(?= (?:\(pronoun))(?: (?:\(numberWord)))*? (?:\(priceScale))(?: (?:\(numberWord)))*\(phraseEnd))", "tính"),
        // "hai trăm rưỡi" = 250
        Rule("trăm rưỡi", "trăm năm mươi"),
        Rule("(?:nghìn|ngàn) rưỡi", "nghìn năm trăm"),
        Rule("triệu rưỡi", "triệu năm trăm nghìn"),
        // Southern "mắc" = expensive, when the talk is about a price (not "mắc kẹt", "mắc lắm" = busy)
        Rule("mắc(?= (?:quá|ghê|vậy|thế))", "đắt",
             context: "giá|tiền|bớt|đắt|rẻ|mua|bán|nghìn|ngàn|triệu|đồng|\\d"),
        // Bargaining: "bớt chút đi" = a small discount (not "bớt đường" = less sugar)
        Rule("bớt (?:cho (?:\(pronoun)|tôi|mình) )?(?:một )?(?:chút xíu|chút|tí|ít)(?=\\s*(?:đi|nha|nhé|được không|[,.!?]|$))", "giảm giá chút"),
        // Idioms the translator takes literally
        Rule("đừng để bụng", "đừng giận"),
        Rule("ăn quả nhớ kẻ trồng cây|uống nước nhớ nguồn", "hãy biết ơn những người đã giúp đỡ mình"),
        Rule("đi đâu mà vội mà vàng", "sao phải vội vàng thế"),
    ]

    private static func apply(_ rules: [Rule], to text: String) -> String {
        var s = text.precomposedStringWithCanonicalMapping
        for rule in rules {
            let range = NSRange(s.startIndex..., in: s)
            if let context = rule.context, context.firstMatch(in: s, range: range) == nil { continue }
            s = rule.regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.template)
        }
        return s
    }

    /// Removes the gaps and stray punctuation left by deletions, and capitalizes a sentence start
    private static func tidy(_ text: String, original: String) -> String {
        var s = text
        for (pattern, template) in [("\\s+", " "), ("\\s+([,.!?])", "$1"), ("([,.!?])[,]+", "$1"),
                                    ("^[\\s,.!]+", ""), ("\\s+$", "")] {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        if let first = s.first, first.isLowercase, original.first?.isUppercase == true {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }
}
