import Foundation
import Testing
@testable import ContextCore

struct SessionTimeTests {
    @Test func classifierSeparatesCIFromLocalRuns() {
        let cases: [(String, SessionTimeActivity)] = [
            ("gh pr checks 12 --watch --interval 30", .ciWait),
            ("until gh pr checks 9 | grep -q pass; do sleep 30; done", .ciWait),
            ("gh run view 1 --log-failed | tail", .ciLogs),
            ("gh run rerun 1 --failed", .ciRerun),
            ("kubectl rollout status deploy/api", .deployCheck),
            ("cd api && go test ./...", .unitTests),
            ("npx playwright test e2e/plan", .e2e),
            ("pnpm lint", .lintFormat),
            ("swift build -c release", .buildCodegen),
            ("git commit -m 'fix lint and tests'", .git),
            ("cd web && git push -u origin fix", .git),
            ("gh pr create --fill", .github),
            ("sleep 30", .sleepPoll),
            ("python3 report.py", .scripts),
            ("rg -n needle src", .shellRead),
        ]
        for (command, expected) in cases {
            #expect(SessionCommandClassifier.classify(command) == expected, "\(command)")
        }
        #expect(SessionCommandClassifier.reportsFailure("tests\tfail\t3m\thttps://example"))
        #expect(!SessionCommandClassifier.reportsFailure("tests\tpass\t3m"))
        #expect(SessionCommandClassifier.reportsFailure("X tests  3m  https://example"))
        #expect(!SessionCommandClassifier.reportsFailure("all checks passed; fix applied"))
        #expect(SessionCommandClassifier.mentionsPendingCI("Pushed. CI is running again, I'll report back."))
        #expect(!SessionCommandClassifier.mentionsPendingCI("Done. The tests pass locally."))
    }

    @Test func claudeTranscriptBecomesCategorisedIntervals() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = 1_790_000_000.0
        func at(_ offset: Double) -> String { iso(base + offset) }
        try writeJSONL([
            ["type": "user", "entrypoint": "cli", "cwd": "/work/app", "sessionId": "s1", "uuid": "u1", "timestamp": at(0),
             "message": ["role": "user", "content": "check CI"]],
            ["type": "assistant", "uuid": "a1", "timestamp": at(5), "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "gh pr checks 3 --watch"]]]]],
            ["type": "user", "uuid": "r1", "timestamp": at(125), "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "tests\tfail\t2m"]]]],
            ["type": "assistant", "uuid": "a2", "timestamp": at(130), "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "git push"]]]]],
            ["type": "user", "uuid": "r2", "timestamp": at(140), "message": ["content": [
                ["type": "tool_result", "tool_use_id": "t2", "content": "ok"]]]],
            ["type": "assistant", "uuid": "a3", "timestamp": at(150), "message": ["stop_reason": "end_turn", "content": [
                ["type": "text", "text": "Pushed the fix. CI is running again."]]]],
            ["type": "user", "uuid": "u2", "timestamp": at(330), "message": ["role": "user", "content": "thanks"]],
        ], to: home.appendingPathComponent(".claude/projects/-work-app/s1.jsonl"))
        try writeJSONL([
            ["type": "user", "entrypoint": "sdk-cli", "cwd": "/work/app", "sessionId": "s2", "uuid": "x1", "timestamp": at(0),
             "message": ["content": "scripted"]],
            ["type": "assistant", "uuid": "x2", "timestamp": at(9), "message": ["stop_reason": "end_turn", "content": []]],
        ], to: home.appendingPathComponent(".claude/projects/-work-app/s2.jsonl"))

        let snapshot = SessionTimeScanner(home: home, cacheDirectory: home.appendingPathComponent("cache")).scan()
        let timeline = try #require(snapshot.timelines.first)
        #expect(snapshot.timelines.count == 1)
        #expect(timeline.folder == "/work/app")
        #expect(timeline.intervals.map(\.activity) == [.model, .ciWait, .model, .git, .model, .replyFewMinutes])
        #expect(timeline.intervals.map(\.duration) == [5, 120, 5, 10, 10, 180])
        #expect(timeline.prompts == [base, base + 330])
        #expect(timeline.signals.contains(.init(time: base + 140, kind: .ciFixCycle, seconds: 15)))
        #expect(timeline.signals.contains(.init(time: base + 330, kind: .ciHandBack, seconds: 180)))
    }

    @Test func codexInteractiveTurnsAndScriptedRunsAreSeparated() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = 1_790_000_000.0
        try writeJSONL([
            ["type": "session_meta", "timestamp": iso(base), "payload": ["id": "c1", "cwd": "/work/api", "originator": "codex-tui", "source": "cli"]],
            ["type": "event_msg", "timestamp": iso(base), "payload": ["type": "task_started", "turn_id": "t1", "turn_attribution": ["turn_trigger": "user"]]],
            ["type": "response_item", "timestamp": iso(base + 2), "payload": ["type": "custom_tool_call", "call_id": "k1", "name": "exec", "input": "go test ./..."]],
            ["type": "response_item", "timestamp": iso(base + 62), "payload": ["type": "custom_tool_call_output", "call_id": "k1", "output": "ok"]],
            ["type": "event_msg", "timestamp": iso(base + 70), "payload": ["type": "task_complete", "turn_id": "t1"]],
            ["type": "event_msg", "timestamp": iso(base + 370), "payload": ["type": "task_started", "turn_id": "t2", "turn_attribution": ["turn_trigger": "user"]]],
            ["type": "event_msg", "timestamp": iso(base + 380), "payload": ["type": "task_complete", "turn_id": "t2"]],
        ], to: home.appendingPathComponent(".codex/sessions/2026/10/01/rollout-a.jsonl"))
        try writeJSONL([
            ["type": "session_meta", "timestamp": iso(base), "payload": ["id": "c2", "cwd": "/work/api", "originator": "codex_exec", "source": "exec"]],
            ["type": "event_msg", "timestamp": iso(base), "payload": ["type": "task_started", "turn_id": "x", "turn_attribution": ["turn_trigger": "exec"]]],
        ], to: home.appendingPathComponent(".codex/sessions/2026/10/01/rollout-b.jsonl"))
        try writeJSONL([
            ["type": "session_meta", "timestamp": iso(base + 10), "payload": ["id": "c3", "cwd": "/work/api", "originator": "codex-tui",
                                                                         "source": ["subagent": ["thread_spawn": ["parent_thread_id": "c1"]]]]],
            ["type": "session_meta", "timestamp": iso(base + 10), "payload": ["id": "c1", "cwd": "/work/api", "originator": "codex-tui", "source": "cli"]],
        ], to: home.appendingPathComponent(".codex/sessions/2026/10/01/rollout-c.jsonl"))

        let snapshot = SessionTimeScanner(home: home, cacheDirectory: home.appendingPathComponent("cache")).scan()
        let main = try #require(snapshot.timelines.first { $0.id == "c1" })
        #expect(snapshot.timelines.count == 2)
        #expect(snapshot.timelines.first { $0.id == "c3" }?.isSubagent == true)
        #expect(main.intervals.map(\.activity) == [.model, .unitTests, .model, .replyHalfHour, .model])
        #expect(main.intervals.map(\.duration) == [2, 60, 8, 300, 10])
        #expect(main.prompts == [base, base + 370])
    }

    @Test func sharedClockCountsEachMomentOnceWithPriority() {
        let a = SessionTimeline(id: "a", agent: .claude, folder: "/home/me/Desktop/acme/web", isSubagent: false,
                                intervals: [.init(start: 0, end: 100, activity: .model)], prompts: [0], signals: [])
        let b = SessionTimeline(id: "b", agent: .claude, folder: "/home/me/Desktop/acme/api", isSubagent: false,
                                intervals: [.init(start: 50, end: 150, activity: .replyHalfHour), .init(start: 150, end: 200, activity: .ciWait)],
                                prompts: [10], signals: [])
        let copy = SessionTimeline(id: "c", agent: .claude, folder: "/home/me/Desktop/acme/api", isSubagent: false,
                                   intervals: [.init(start: 150, end: 200, activity: .ciWait)], prompts: [], signals: [])
        let snapshot = SessionTimeSnapshot(generatedAt: Date(), timelines: [a, b, copy], history: [], coverage: [])
        let report = SessionTimeReport.build(snapshot: snapshot, filter: .init(timeZone: TimeZone(identifier: "UTC")!, scale: .day), home: "/home/me")

        #expect(report.groupSeconds[.model] == 100)
        #expect(report.groupSeconds[.you] == 100)
        #expect(report.groupSeconds[.ciCD] == 50, "the duplicated CI interval counts once")
        #expect(report.stateSeconds[.working] == 100)
        #expect(report.stateSeconds[.waitingOnYou] == 50)
        #expect(report.stateSeconds[.ciOnly] == 50)
        #expect(report.workspaces.first?.key == "~/Desktop/acme")
        // Active for 15 minutes after each prompt; two sessions are live from 50 to 100.
        #expect(report.liveWhileActive[2] == 50)
        #expect(report.liveWhileActive[1] == 150)
    }

    @Test func periodsSplitAtMidnightInTheChosenTimeZone() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2))).timeIntervalSince1970
        let timeline = SessionTimeline(id: "a", agent: .codex, folder: "/w", isSubagent: false,
                                       intervals: [.init(start: midnight - 600, end: midnight + 1200, activity: .unitTests)],
                                       prompts: [midnight - 600], signals: [])
        let snapshot = SessionTimeSnapshot(generatedAt: Date(), timelines: [timeline], history: [], coverage: [])
        let report = SessionTimeReport.build(snapshot: snapshot, filter: .init(timeZone: zone, scale: .day))
        #expect(report.periods.count == 2)
        #expect(report.periods.map { $0.groupSeconds[.localRuns] ?? 0 } == [600, 1200])
        #expect(report.periods.first?.prompts == 1)
    }

    @Test func unchangedFilesComeFromTheCache() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeJSONL([
            ["type": "user", "entrypoint": "cli", "cwd": "/w", "sessionId": "s", "uuid": "1", "timestamp": iso(1_790_000_000), "message": ["content": "hi"]],
            ["type": "assistant", "uuid": "2", "timestamp": iso(1_790_000_004), "message": ["stop_reason": "end_turn", "content": []]],
        ], to: home.appendingPathComponent(".claude/projects/-w/s.jsonl"))
        let scanner = SessionTimeScanner(home: home, cacheDirectory: home.appendingPathComponent("cache"))
        let first = scanner.scan()
        let second = scanner.scan()
        #expect(first.timelines == second.timelines)
        #expect(second.coverage.first { $0.agent == .claude }?.cachedFiles == 1)
    }

    @Test func promptHistoryDropsScriptedSessions() {
        let prompts = [
            SessionTimeHistoryPrompt(time: 1, folder: "/w", session: "real"),
            SessionTimeHistoryPrompt(time: 2, folder: "/w", session: "real"),
            SessionTimeHistoryPrompt(time: 3, folder: "/w", session: "one-shot"),
            SessionTimeHistoryPrompt(time: 4, folder: "/w", session: "short-but-real"),
            SessionTimeHistoryPrompt(time: 5, folder: "/w", session: "sdk"),
            SessionTimeHistoryPrompt(time: 6, folder: "/w", session: "sdk"),
        ]
        let kept = SessionTimeScanner.interactiveHistory(prompts, scripted: ["sdk"], interactive: ["short-but-real"])
        #expect(kept.map(\.session) == ["real", "real", "short-but-real"])
    }

    // MARK: Fixtures

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func iso(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func writeJSONL(_ rows: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
