import Foundation
import Testing
@testable import ContextCore

struct AgentActivityFilesTests {
    @Test func allAgentsReadOnlyTheirOwnActivityMetadata() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths: [(AgentRuntime, String)] = [
            (.codex, ".codex/sessions/2026/09/run.jsonl"),
            (.claude, ".claude/projects/example/run.jsonl"),
            (.cursor, ".cursor/projects/example/agent-transcripts/run.txt"),
            (.devin, ".local/share/devin/cli/transcripts/run.json"),
            (.grok, ".grok/sessions/example/run/events.jsonl")
        ]
        for (_, path) in paths {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Invalid transcript data is intentionally sufficient: no parsing/body access is required.
            try Data([0xFF, 0x00]).write(to: url)
        }
        let excluded = home.appendingPathComponent(".grok/sessions/prompt_history.jsonl")
        try Data("private prompt".utf8).write(to: excluded)
        let unrelated = home.appendingPathComponent(".cursor/projects/unrelated.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        for (runtime, path) in paths {
            let result = AgentActivityFiles.scan(runtime: runtime, home: home)
            #expect(result.files.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == [home.appendingPathComponent(path).resolvingSymlinksInPath().path])
            #expect(!result.partial)
        }
    }

    @Test func missingLimitedAndLinkedSourcesAreNotCompleteHistory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let absent = AgentActivityFiles.scan(runtime: .cursor, home: home)
        #expect(absent.files.isEmpty)
        #expect(absent.status.contains("No local activity folder"))
        let root = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = home.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data().write(to: external.appendingPathComponent("private.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: external)
        #expect(AgentActivityFiles.scan(runtime: .codex, home: home).files.isEmpty)
        let limited = AgentActivityFiles.scan(runtime: .codex, home: home, maximumEntries: 0)
        #expect(limited.partial)
        let cursor = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cursor.appendingPathComponent("projects"), withDestinationURL: external)
        let linkedRoot = AgentActivityFiles.scan(runtime: .cursor, home: home)
        #expect(linkedRoot.partial)
        #expect(linkedRoot.status.contains("Linked activity root"))
        #expect(linkedRoot.files.isEmpty)
    }
}
