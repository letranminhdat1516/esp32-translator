import Foundation
import Testing
@testable import ClaudeBoardCore

let bashRequest = """
{"session_id":"s1","cwd":"/Users/me/Documents/esp32-translator","hook_event_name":"PermissionRequest",
 "tool_name":"Bash","tool_input":{"command":"npm test -- --watch=false","description":"Run tests"}}
""".data(using: .utf8)!

@Test func parsesPermissionRequest() throws {
    let e = try HookEvent.parse(bashRequest)
    #expect(e.name == "PermissionRequest")
    #expect(e.toolName == "Bash")
    #expect(Summary.project(cwd: e.cwd) == "esp32-translator")
    #expect(Summary.permission(e) == "npm test -- --watch=false")
}

@Test func summaryPicksFilePathForEdits() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/p/src/app/main.swift","old_string":"a","new_string":"b"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "src/app/main.swift")
}

@Test func summaryFallsBackToFirstString() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"mcp__x__y","tool_input":{"query":"weather in Hanoi"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "weather in Hanoi")
}

@Test func trimsByCharacterNotByte() {
    let s = String(repeating: "ữ", count: 200)
    let t = Summary.trim(s, maxChars: 10)
    #expect(t.count == 10)
    #expect(t.hasSuffix("…"))
    #expect(String(data: t.data(using: .utf8)!, encoding: .utf8) == t)
}

@Test func multilineCommandsBecomeOneLine() throws {
    let e = try HookEvent.parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"cd x\nmake all"}}"#.data(using: .utf8)!)
    #expect(Summary.permission(e) == "cd x ⏎ make all")
}

@Test func encodesPermissionMessage() {
    let d = BoardMessage.permission(id: 0x01020304, project: "p", tool: "Bash", summary: "ls").encode()
    #expect(Array(d) == [0, 0x04, 0x03, 0x02, 0x01] + Array("p\nBash\nls".utf8))
}

@Test func encodesCancel() {
    #expect(Array(BoardMessage.cancel(id: 7).encode()) == [2, 7, 0, 0, 0])
}

@Test func chunksCarryFirstAndLastFlags() {
    let data = Data(repeating: 0x41, count: 25)
    let c = BoardMessage.chunks(data, maxChunk: 11)          // 10 payload bytes per chunk
    #expect(c.count == 3)
    #expect(c[0].first == 0x01 && c[1].first == 0x00 && c[2].first == 0x02)
    #expect(c.map { $0.count - 1 }.reduce(0, +) == 25)
    #expect(BoardMessage.chunks(Data([1]), maxChunk: 20).first?.first == 0x03)
}

@Test func decodesAnswer() {
    let a = Answer.decode(Data([0x04, 0x03, 0x02, 0x01, 1]))
    #expect(a?.id == 0x01020304 && a?.decision == .allow)
    #expect(Answer.decode(Data([1, 2, 3])) == nil)
    #expect(Answer.decode(Data([1, 0, 0, 0, 9])) == nil)
}
