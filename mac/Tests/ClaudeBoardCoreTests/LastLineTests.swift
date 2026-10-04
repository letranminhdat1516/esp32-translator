import Foundation
import Testing
@testable import ClaudeBoardCore

private func event(message: String? = nil, transcript: String? = nil) -> HookEvent {
    HookEvent(name: "Stop", sessionId: "s", cwd: "/p", toolName: nil, toolInput: [:],
              notificationType: nil, lastAssistantMessage: message, transcriptPath: transcript)
}

private func tempFile(_ contents: String) throws -> String {
    let path = NSTemporaryDirectory() + "lastline-\(UUID().uuidString).jsonl"
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Test func lastLineUsesLastAssistantMessageLastLine() {
    #expect(Summary.lastLine(event(message: "first\nDone: all tests pass\n")) == "Done: all tests pass")
}

@Test func lastLineReadsLastAssistantTextFromTranscript() throws {
    let path = try tempFile("""
    {"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"old reply"}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"line one\\nFinal line"},{"type":"tool_use","name":"Bash"}]}}
    {"type":"user","message":{"content":[{"type":"text","text":"thanks"}]}}
    not json
    """)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(Summary.lastLine(event(transcript: path)) == "Final line")
}

@Test func lastLineTrimsLongText() {
    let s = Summary.lastLine(event(message: String(repeating: "x", count: 500)))
    #expect(s.count == 140)
    #expect(s.hasSuffix("…"))
}

@Test func lastLineMissingOrGarbledTranscriptIsEmpty() throws {
    #expect(Summary.lastLine(event(transcript: "/nonexistent/path.jsonl")) == "")
    let path = try tempFile("garbage\n{broken")
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(Summary.lastLine(event(transcript: path)) == "")
    #expect(Summary.lastLine(event()) == "")
}
