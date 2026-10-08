import Foundation
import Testing
@testable import ContextCore

struct SkillUsageEvidenceTests {
    @Test func claudeSlashCommandsCountAsExplicitInvocations() throws {
        let home = try fixture()
        try writeJSONL([
            ["type": "user", "sessionId": "s1", "uuid": "u1", "cwd": "/work/app", "timestamp": "2026-10-01T10:00:00Z",
             "message": ["role": "user", "content": "<command-message>graphify</command-message>\n<command-name>/graphify</command-name>\n<command-args></command-args>"]],
            ["type": "user", "sessionId": "s1", "uuid": "u2", "timestamp": "2026-10-02T10:00:00Z",
             "message": ["role": "user", "content": [["type": "text", "text": "<command-name>/cardboard:cardboard</command-name>"]]]],
            // An assistant quoting the tag is not a user invocation.
            ["type": "assistant", "sessionId": "s1", "uuid": "u3",
             "message": ["content": [["type": "text", "text": "<command-name>/humanizer</command-name>"]]]],
        ], to: home.appendingPathComponent(".claude/projects/app/run.jsonl"))
        let snapshot = SkillActivityHistory(home: home).scan()
        let commands = snapshot.observations.filter { $0.evidence == .slashCommand }
        #expect(commands.map(\.name).sorted() == ["cardboard", "graphify"])
        #expect(commands.allSatisfy { $0.runtime == .claude })
        let graphify = SkillRecord(id: "/home/.claude/skills/graphify/SKILL.md", name: "graphify", description: "", logicalBytes: 0, modified: .now, exposures: [], policies: [])
        let summary = snapshot.summary(for: graphify)
        #expect(summary.explicitInvocations == 1)
        #expect(summary.lastSeen == "2026-10-01")
    }

    @Test func codexDollarMentionsCountOnlyInRealUserMessages() throws {
        let home = try fixture()
        let catalog = "<skills_instructions>\n- $catalog-only: listed skill\n</skills_instructions>"
        try writeJSONL([
            ["type": "session_meta", "payload": ["cwd": "/work/app"]],
            ["type": "response_item", "timestamp": "2026-10-03T09:00:00Z", "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "# AGENTS.md instructions for /work/app\n\nUse $agents-only when asked."],
                ["type": "input_text", "text": catalog],
            ]]],
            ["type": "response_item", "timestamp": "2026-10-03T09:01:00Z", "payload": ["type": "message", "role": "developer", "content": [
                ["type": "input_text", "text": "Prefer $developer-only."],
            ]]],
            ["type": "response_item", "timestamp": "2026-10-03T09:02:00Z", "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "Run $design-workflow on this page, keep $HOME and costs under $5. Then $design-workflow again."],
            ]]],
            ["type": "response_item", "timestamp": "2026-10-03T09:03:00Z", "payload": ["type": "message", "role": "assistant", "content": [
                ["type": "output_text", "text": "I will use $assistant-only."],
            ]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Run $design-workflow on this page"]],
        ], to: home.appendingPathComponent(".codex/sessions/2026/10/03/run.jsonl"))
        let mentions = SkillActivityHistory(home: home).scan().observations.filter { $0.evidence == .explicitMention }
        #expect(mentions.map(\.name) == ["design-workflow"])
        #expect(mentions.first?.runtime == .codex)
        #expect(mentions.first?.project == "/work/app")
        #expect(mentions.first?.day == "2026-10-03")
    }

    @Test func snapshotPersistsAcrossStoreInstances() async throws {
        let directory = try fixture()
        let snapshot = SkillActivitySnapshot(observations: [
            .init(name: "alpha", runtime: .claude, evidence: .slashCommand, session: "s", day: "2026-10-01", project: nil, skillPath: nil, failed: false),
        ], coverage: [.init(runtime: .claude, files: 3, partial: false, note: "ok", firstDay: "2026-09-01", lastDay: "2026-10-01")],
           scannedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try await SkillActivitySnapshotStore(directory: directory).save(snapshot)
        let loaded = try #require(await SkillActivitySnapshotStore(directory: directory).load())
        #expect(loaded.observations.first?.evidence == .slashCommand)
        #expect(loaded.coverage.first?.dayRange == "2026-09-01 to 2026-10-01")
        #expect(loaded.scannedAt == snapshot.scannedAt)
    }

    @Test func zeroInvocationFindingStatesMeasuredCoverage() {
        func record(_ name: String, _ mode: InvocationMode) -> SkillRecord {
            SkillRecord(id: "/home/.agents/skills/\(name)/SKILL.md", name: name, description: "d", logicalBytes: 0, modified: .now, exposures: [],
                        policies: [.init(runtime: .codex, mode: mode, explicit: true, reason: "", invocation: ""),
                                   .init(runtime: .claude, mode: mode, explicit: true, reason: "", invocation: "")])
        }
        let snapshot = SkillActivitySnapshot(observations: [
            .init(name: "used", runtime: .codex, evidence: .explicitMention, session: "s", day: "2026-10-01", project: nil, skillPath: nil, failed: false),
            .init(name: "devin-only", runtime: .devin, evidence: .toolCall, session: "d", day: "2026-10-01", project: nil, skillPath: nil, failed: false),
        ], coverage: [
            .init(runtime: .codex, files: 732, partial: false, note: "", firstDay: "2026-08-01", lastDay: "2026-10-08"),
            .init(runtime: .claude, files: 644, partial: false, note: "", firstDay: "2026-09-13", lastDay: "2026-10-08"),
        ], scannedAt: .now)
        let result = SkillActivityFindings.zeroInvocations(records: [record("used", .automatic), record("idle", .automatic), record("devin-only", .automatic), record("manual", .manualOnly)], snapshot: snapshot)
        #expect(result.issues.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent }.sorted() == ["devin-only", "idle"])
        let detail = result.issues.first?.detail ?? ""
        #expect(detail.contains("0 invocations"))
        #expect(detail.contains("732 Codex + 644 Claude session files"))
        #expect(detail.contains("2026-08-01 to 2026-10-08"))
        #expect(!detail.lowercased().contains("unused"))
        #expect(result.issues.allSatisfy { $0.severity == .warning })
        #expect(result.files.count == 3)

        // No scanned Codex or Claude history: no claims.
        let empty = SkillActivitySnapshot(observations: [], coverage: [.init(runtime: .codex, files: 0, partial: true, note: "No local history folder")], scannedAt: .now)
        #expect(SkillActivityFindings.zeroInvocations(records: [record("idle", .automatic)], snapshot: empty).issues.isEmpty)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func writeJSONL(_ values: [Any], to url: URL) throws {
        let rows = try values.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}
