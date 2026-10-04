import Foundation

public enum Summary {
    public static func project(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    /// The single most useful field of the tool input, on one line
    public static func permission(_ e: HookEvent, maxChars: Int = 120) -> String {
        let input = e.toolInput
        let raw: String
        if let cmd = input["command"]?.string {
            raw = cmd
        } else if let path = input["file_path"]?.string ?? input["notebook_path"]?.string {
            raw = relative(path, to: e.cwd)
        } else if let url = input["url"]?.string {
            raw = url
        } else if let first = input.keys.sorted().compactMap({ input[$0]?.string }).first {
            raw = first
        } else {
            raw = e.toolName ?? "permission"
        }
        let oneLine = raw.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return trim(oneLine, maxChars: maxChars)
    }

    public static func trim(_ s: String, maxChars: Int) -> String {
        s.count <= maxChars ? s : String(s.prefix(maxChars - 1)) + "…"
    }

    private static func relative(_ path: String, to cwd: String) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

extension Summary {
    /// Last line of Claude's reply, for the "finished" message. Prefers the hook's
    /// `last_assistant_message`, else the last assistant text in the transcript JSONL. "" if unavailable.
    public static func lastLine(_ e: HookEvent, maxChars: Int = 140) -> String {
        if let m = e.lastAssistantMessage { return lastLine(ofText: m, maxChars: maxChars) }
        guard let p = e.transcriptPath, let text = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]],
                  let t = content.compactMap({ $0["text"] as? String }).last else { continue }
            return lastLine(ofText: t, maxChars: maxChars)
        }
        return ""
    }

    private static func lastLine(ofText t: String, maxChars: Int) -> String {
        trim(t.split(whereSeparator: \.isNewline).last.map(String.init) ?? t, maxChars: maxChars)
    }
}
