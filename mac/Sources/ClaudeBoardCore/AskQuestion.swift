import Foundation

public struct AskOption: Equatable, Sendable {
    public let label: String
    public let description: String
    public init(label: String, description: String) { self.label = label; self.description = description }
}

/// One AskUserQuestion question as the board shows it (one page each).
public struct AskQuestion: Equatable, Sendable {
    public let question: String
    public let header: String
    public let options: [AskOption]
    public let multiSelect: Bool

    public static let maxQuestions = 4
    public static let maxOptions = 4

    public init(question: String, header: String, options: [AskOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The questions in an AskUserQuestion tool_input, or nil when the board cannot show them (then Claude
    /// asks in the terminal): no questions, more than 4 questions, 0 or more than 4 options, an empty label,
    /// or two questions with the same text (answers are keyed by the question text).
    public static func parse(_ input: [String: JSONValue]) -> [AskQuestion]? {
        guard let list = input["questions"]?.array, (1...maxQuestions).contains(list.count) else { return nil }
        var out: [AskQuestion] = []
        for item in list {
            guard let o = item.object, let question = o["question"]?.string,
                  let opts = o["options"]?.array, (1...maxOptions).contains(opts.count) else { return nil }
            var options: [AskOption] = []
            for opt in opts {
                guard let oo = opt.object, let label = oo["label"]?.string,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                options.append(AskOption(label: label, description: oo["description"]?.string ?? ""))
            }
            out.append(AskQuestion(question: question, header: o["header"]?.string ?? "", options: options,
                                   multiSelect: o["multiSelect"]?.bool ?? false))
        }
        guard Set(out.map(\.question)).count == out.count else { return nil }
        return out
    }
}
