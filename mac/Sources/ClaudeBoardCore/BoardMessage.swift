import Foundation

public enum Decision: UInt8, Sendable { case allow = 1, deny = 2 }

public enum BoardMessage: Equatable, Sendable {
    /// alwaysRule: caption of the rule "Always allow" would add; nil = the button is not offered
    case permission(id: UInt32, project: String, tool: String, summary: String, alwaysRule: String? = nil)
    case finished(id: UInt32, project: String, line: String)
    case cancel(id: UInt32)
    /// Wall clock for the board's lock face: Unix seconds and the local UTC offset in minutes
    case time(unixSeconds: Int64, offsetMinutes: Int)
    case session(SessionRow)
    case sessionRemove(handle: UInt32)
    case sessionsClear
    /// One AskUserQuestion page; all pages of a request share its id
    case question(id: UInt32, index: Int, count: Int, project: String, question: AskQuestion)

    /// Firmware CLAUDE_TEXT_MAX: the text after the 5-byte header never exceeds this many bytes
    public static let textMax = 400

    /// [kind u8][id u32 LE][UTF-8 text]. Kinds: 0 permission "project\ntool\nsummary[\nrule]", 1 finished
    /// "project\nline", 2 cancel, 3 time (id 0, "<unix seconds> <offset minutes>"), 4 session (id = handle,
    /// "<state> <since> <updated> <flags>\nproject\nline"), 5 session remove (id = handle), 6 sessions clear
    /// (id 0), 7 question page "<index> <count> <multi> <nopt>\nproject\nheader\nquestion\n(label\ndesc)xnopt".
    public func encode() -> Data {
        let (kind, id, text): (UInt8, UInt32, String) = switch self {
        case .permission(let id, let p, let t, let s, let rule): (0, id, Self.permissionText(p, t, s, rule))
        case .finished(let id, let p, let l): (1, id, Self.headAndRest([(p, 60)], rest: l))
        case .cancel(let id): (2, id, "")
        case .time(let seconds, let offset): (3, 0, "\(seconds) \(offset)")
        case .session(let r):
            (4, r.handle, Self.headAndRest([("\(r.state.rawValue) \(r.since) \(r.updated) \(r.flags)", 64), (r.project, 60)],
                                           rest: r.lastLine))
        case .sessionRemove(let h): (5, h, "")
        case .sessionsClear: (6, 0, "")
        case .question(let id, let index, let count, let project, let q): (7, id, Self.questionText(index, count, project, q))
        }
        var d = Data([kind, UInt8(id & 0xff), UInt8(id >> 8 & 0xff), UInt8(id >> 16 & 0xff), UInt8(id >> 24)])
        d.append(contentsOf: text.utf8)
        return d
    }

    private static func line(_ s: String, _ max: Int) -> String { Utf8.fit(Utf8.oneLine(s), maxBytes: max) }

    /// Capped fields, then one last field that gets every byte left (newlines included in the count).
    private static func headAndRest(_ head: [(String, Int)], rest: String) -> String {
        let fields = head.map { line($0.0, $0.1) }
        let used = fields.reduce(0) { $0 + $1.utf8.count } + fields.count
        return (fields + [line(rest, max(0, textMax - used))]).joined(separator: "\n")
    }

    private static func permissionText(_ p: String, _ t: String, _ s: String, _ rule: String?) -> String {
        var fields = [line(p, 60), line(t, 60)]
        let ruleLine = rule.map { line($0, 80) }
        let used = fields.reduce(0) { $0 + $1.utf8.count } + (ruleLine?.utf8.count ?? 0) + (ruleLine == nil ? 2 : 3)
        fields.append(line(s, max(0, textMax - used)))
        if let ruleLine { fields.append(ruleLine) }
        return fields.joined(separator: "\n")
    }

    private static func questionText(_ index: Int, _ count: Int, _ project: String, _ q: AskQuestion) -> String {
        let head = ["\(index) \(count) \(q.multiSelect ? 1 : 0) \(q.options.count)",
                    line(project, 32), line(q.header, 24), line(q.question, 120)]
        let labels = q.options.map { line($0.label, 32) }
        let newlines = head.count + 2 * labels.count - 1
        let used = (head + labels).reduce(0) { $0 + $1.utf8.count } + newlines
        let descs = Utf8.share(q.options.map { Utf8.oneLine($0.description) }, totalBytes: textMax - used)
        var fields = head
        for (l, d) in zip(labels, descs) { fields.append(l); fields.append(d) }
        return fields.joined(separator: "\n")
    }

    /// The time message for `date` as seen in `timeZone` (daylight saving included).
    public static func timeSync(at date: Date = Date(), in timeZone: TimeZone = .current) -> BoardMessage {
        .time(unixSeconds: Int64(date.timeIntervalSince1970.rounded(.down)),
              offsetMinutes: timeZone.secondsFromGMT(for: date) / 60)
    }

    /// Splits a message into BLE writes: [flags u8][payload], flags bit0 = first, bit1 = last
    public static func chunks(_ data: Data, maxChunk: Int) -> [Data] {
        let size = max(1, maxChunk - 1)
        var out: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= 0x01 }
            if end == data.count { flags |= 0x02 }
            out.append(Data([flags]) + data[data.startIndex + offset ..< data.startIndex + end])
            offset = end
        } while offset < data.count
        return out
    }
}
