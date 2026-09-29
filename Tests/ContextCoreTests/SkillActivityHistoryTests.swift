import Foundation
import Testing
@testable import ContextCore

struct SkillActivityHistoryTests {
    @Test func oversizedRecordMakesCoveragePartialWithoutHidingLaterCalls() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".claude/projects/example/run.jsonl")
        try write(String(repeating: "x", count: 2_000) + "\n" +
                  "{\"type\":\"assistant\",\"sessionId\":\"one\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Skill\",\"id\":\"call\",\"input\":{\"skill\":\"alpha\"}}]}}\n",
                  to: path)
        var limits = SkillActivityHistory.Limits()
        limits.maximumLineBytes = 1_000
        let snapshot = SkillActivityHistory(home: home, limits: limits).scan()
        let claude = try #require(snapshot.coverage.first { $0.runtime == .claude })
        #expect(claude.partial)
        #expect(claude.skippedRecords == 1)
        #expect(claude.note.contains("oversized records skipped"))
        #expect(snapshot.observations.filter { $0.runtime == .claude }.count == 1)
    }

    @Test func structuredHistorySeparatesCallsFromFileEvidence() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = home.appendingPathComponent(".agents/skills/alpha/SKILL.md")
        try write("---\nname: alpha\n---\n", to: skill)
        let project = home.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try writeJSONL([
            ["type": "session_meta", "payload": ["cwd": project.path]],
            ["type": "response_item", "timestamp": "2026-09-28T10:00:00Z",
             "payload": ["type": "custom_tool_call", "input": "cat \(skill.path)"]],
            ["type": "response_item", "timestamp": "2026-09-28T10:01:00Z",
             "payload": ["type": "custom_tool_call", "input": "sed -n '1,20p' \(skill.path)"]],
            ["type": "response_item", "payload": ["type": "message", "content": "\(skill.path) appears in a discussion"]],
        ], to: home.appendingPathComponent(".codex/sessions/2026/09/run.jsonl"))

        try writeJSONL([
            ["type": "assistant", "sessionId": "claude-one", "cwd": project.path, "timestamp": "2026-09-27T10:00:00Z",
             "message": ["content": [["type": "tool_use", "name": "Skill", "id": "call-one", "input": ["skill": "alpha"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "call-one", "is_error": false]]]],
            ["type": "assistant", "sessionId": "claude-one", "cwd": project.path, "timestamp": "2026-09-27T10:02:00Z",
             "message": ["content": [["type": "tool_use", "name": "Skill", "id": "call-two", "input": ["skill": "alpha"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "call-two", "is_error": true]]]],
        ], to: home.appendingPathComponent(".claude/projects/example/run.jsonl"))

        try writeJSON(["session_id": "devin-one", "steps": [["timestamp": "2026-09-26T10:00:00Z",
            "tool_calls": [["function_name": "skill", "tool_call_id": "devin-call", "arguments": ["skill": "alpha"]]]]]],
            to: home.appendingPathComponent(".local/share/devin/cli/transcripts/run.json"))

        try writeJSONL([[
            "role": "assistant", "message": ["content": [["type": "tool_use", "name": "Read", "input": ["path": skill.path]]]],
        ]], to: home.appendingPathComponent(".cursor/projects/example/agent-transcripts/run.jsonl"))

        try writeJSONL([[
            "timestamp": 1_790_000_000, "params": ["sessionId": "grok-one", "update": [
                "toolCallId": "grok-call", "rawInput": ["target_file": skill.path],
                "_meta": ["x.ai/tool": ["name": "read_file"]],
            ]],
        ]], to: home.appendingPathComponent(".grok/sessions/example/events.jsonl"))

        let snapshot = SkillActivityHistory(home: home).scan()
        let record = SkillRecord(id: skill.path, name: "alpha", description: "", logicalBytes: 0,
                                 modified: .now, exposures: [], policies: [])
        let all = snapshot.summary(for: record)
        #expect(all.toolCalls == 3)
        #expect(all.failedToolCalls == 1)
        #expect(all.fileReadSessions == 2)
        #expect(all.pathReferenceSessions == 1)
        #expect(all.lastSeen != nil)
        #expect(snapshot.coverage.allSatisfy { !$0.partial && $0.files == 1 })

        let scoped = snapshot.summary(for: record, folder: project.path)
        #expect(scoped.toolCalls == 2)
        #expect(scoped.pathReferenceSessions == 1)
        #expect(scoped.fileReadSessions == 0)
        #expect(snapshot.summary(for: record, runtime: .codex, sinceDay: "2026-09-29").isEmpty)

        let otherCopy = SkillRecord(id: home.appendingPathComponent("other/skills/alpha/SKILL.md").path,
                                    name: "alpha", description: "", logicalBytes: 0, modified: .now,
                                    exposures: [], policies: [])
        #expect(snapshot.summary(for: otherCopy).toolCalls == 3)
        #expect(snapshot.summary(for: otherCopy).fileReadSessions == 0)
        #expect(snapshot.summary(for: otherCopy).pathReferenceSessions == 0)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func writeJSONL(_ values: [Any], to url: URL) throws {
        let rows = try values.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try write(rows.joined(separator: "\n") + "\n", to: url)
    }
}
