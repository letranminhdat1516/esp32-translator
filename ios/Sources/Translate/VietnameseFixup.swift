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
        tidy(apply(translationRules, to: apply(loanwordRules, to: text)), original: text)
    }

    // MARK: Rules

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // Whole words only: no letter or digit may touch the match
            let bounded = "(?<![\\p{L}\\p{N}])(?:\(pattern))(?![\\p{L}\\p{N}])"
            regex = try! NSRegularExpression(pattern: bounded, options: [.caseInsensitive])
            self.template = template
        }
    }

    /// Observed in the measurement spike (25 sentences × 13 conditions), plus spelling variants
    private static let loanwordRules: [Rule] = [
        Rule("gran(?:t|d)? (?:out|ao)|grab out|gờ ráp|xe ra rounds", "Grab"),
        Rule("(?<=xe )gram", "Grab"),
        Rule("hoa phay|hoa pha(?! lê)|oai phai|quai phai|wai phai|wi fi|wifi", "Wi-Fi"),
        Rule("(?<=mật khẩu )(?:khoai tây|phai)", "Wi-Fi"),
        Rule("(?<=(?:qua|bằng|trên|dùng|có|gửi|nhắn|gọi) )giữa lo(?! (?:lắng|âu|sợ|ngại|xa|liệu|nghĩ))|zalo lo|da lô|za lô|gia lô", "Zalo"),
        Rule("china com|(?:c|phi) nga (?:co|to|tho)|c call|syria tho|xin ga po|xing ga po|sing ga po|singapo", "Singapore"),
        Rule("phây búc|phây bút|phê búc|phết búc|face book", "Facebook"),
        Rule("i meo|i-meo|e mail|e-mail|ê meo", "email"),
        Rule("ô kê|ô-kê|oke|okê|okey", "OK"),
        // "ở" heard as "ngở" after a nasal ending ("ngở" is not a Vietnamese word)
        Rule("ngở", "ở"),
    ]

    private static let pronoun = "em|anh|chị|cô|chú|bác|ông|bà|bạn|cháu|con|dì|cậu|mợ|thím"
    /// A number is a price only with a scale word or three digits ("hai cái" is a count)
    private static let priceScale = "trăm|nghìn|ngàn|triệu|rưỡi|chục|k|đồng|\\d+[.,]\\d{3}|\\d{3,}"
    private static let numberWord = "\\d[\\d.,]*|một|hai|ba|bốn|tư|năm|lăm|sáu|bảy|tám|chín|mười|mươi|mốt|trăm|nghìn|ngàn|triệu|rưỡi|chục|k"

    private static let translationRules: [Rule] = [
        // Vocatives: "em ơi", "anh ơi"… anywhere, and a bare "ơi" (not "trời ơi", "mẹ ơi": those are exclamations)
        Rule("(?:\(pronoun)) ơi[,!.]?", ""),
        Rule("(?<![\\p{L}] )ơi[,!.]?", ""),
        // Asking for the bill
        Rule("tính tiền(?: (?:đi|nhé|nha|ạ|giùm|dùm|với|cho (?:\(pronoun)|tôi|mình)))*(?=\\s*(?:[,.!?]|$))", "cho tôi thanh toán"),
        // A seller's "em lấy anh 250 nghìn" is a price, not "I marry you"
        Rule("lấy(?= (?:\(pronoun))(?: (?:\(numberWord)))*? (?:\(priceScale))(?![\\p{L}\\p{N}]))", "tính"),
        // "hai trăm rưỡi" = 250
        Rule("trăm rưỡi", "trăm năm mươi"),
        Rule("(?:nghìn|ngàn) rưỡi", "nghìn năm trăm"),
        Rule("triệu rưỡi", "triệu năm trăm nghìn"),
        // Southern "mắc" = expensive (but not "mắc kẹt", "mắc mưa"…)
        Rule("mắc(?= (?:quá|vậy|thế|ghê|lắm))", "đắt"),
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
