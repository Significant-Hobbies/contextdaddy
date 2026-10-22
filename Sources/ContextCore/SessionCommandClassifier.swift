import Foundation

/// Maps a shell command to an activity. The command is read in memory only.
public enum SessionCommandClassifier {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let ci = regex(#"gh pr checks|gh run (view|list|watch|rerun)|gh workflow|statusCheckRollup|/actions/(runs|jobs)|mergeStateStatus"#)
    private static let ciRerun = regex(#"rerun|gh workflow run|allow-empty"#)
    private static let ciWait = regex(#"--watch|gh run watch|\bsleep\b|\buntil\b|\bwhile\b"#)
    private static let ordered: [(NSRegularExpression, SessionTimeActivity)] = [
        (regex(#"argocd|kubectl|helm "#), .deployCheck),
        (regex(#"playwright|maestro|\be2e\b|test:e2e|idb |simctl"#), .e2e),
        (regex(#"go test|jest|vitest|pnpm (run )?test|npm (run )?test|pytest|yarn test|bun test|cargo test|swift test|xcodebuild test"#), .unitTests),
        (regex(#"\btsc\b|typecheck|lint|prettier|biome|eslint|gofmt|go vet|golangci|clippy|swiftlint|swift-format"#), .lintFormat),
        (regex(#"go build|pnpm (run )?build|npm run build|expo export|docker build|generate|\bmake\b|atlas |cargo build|swift build|xcodebuild"#), .buildCodegen),
        (regex(#"pnpm (i|install)|npm (ci|i|install)|go mod|uv (sync|pip)|brew |pip install|npx -y"#), .install),
        (regex(#"localhost|127\.0\.0\.1|docker|lsof -i|pm2|nohup|dev server|expo start"#), .localStack),
        (regex(#"mysql|psql|prisma|sqlite"#), .database),
        (regex(#"terminal-browser|agent-browser|screenshot|chrome|puppeteer"#), .browser),
    ]
    private static let leadingGit = regex(#"^\s*(cd [^;&]+(&&|;)\s*)?git "#)
    private static let git = regex(#"git (push|commit|fetch|rebase|merge|worktree|pull|checkout|log|diff|status|show)"#)
    private static let github = regex(#"\bgh "#)
    private static let sleep = regex(#"^\s*sleep \d+\s*$"#)
    private static let scripts = regex(#"python3?|node |npx |tsx "#)
    private static let shellRead = regex(#"\b(grep|rg|find|cat|sed|ls|head|tail|wc|jq|awk|diff)\b"#)

    public static func classify(_ command: String) -> SessionTimeActivity {
        let text = command as NSString
        let range = NSRange(location: 0, length: text.length)
        func matches(_ pattern: NSRegularExpression) -> Bool { pattern.firstMatch(in: command, range: range) != nil }
        if matches(ci) {
            if matches(ciRerun) { return .ciRerun }
            if matches(ciWait) { return .ciWait }
            return .ciLogs
        }
        // A command that starts with git is git, even when its message mentions tests or lint.
        if matches(leadingGit) { return .git }
        for (pattern, activity) in ordered where matches(pattern) { return activity }
        if matches(git) { return .git }
        if matches(github) { return .github }
        if matches(sleep) { return .sleepPoll }
        if matches(scripts) { return .scripts }
        if matches(shellRead) { return .shellRead }
        return .shellOther
    }

    private static let failure = try! NSRegularExpression(
        pattern: #"\tfail\t|\bfail(ed|ure|ing)?\b|conclusion":\s*"failure"#, options: [.caseInsensitive])
    // gh marks failing checks with ✗ or a capital X; matched case-sensitively so "fix " does not count.
    private static let failureMark = try! NSRegularExpression(pattern: #"✗|(^|\s)X "#, options: [.anchorsMatchLines])

    /// Whether CI output reports a failing check. Reads at most the first 3,000 characters.
    public static func reportsFailure(_ output: String) -> Bool {
        let head = String(output.prefix(3_000))
        let range = NSRange(location: 0, length: (head as NSString).length)
        return failure.firstMatch(in: head, range: range) != nil || failureMark.firstMatch(in: head, range: range) != nil
    }

    private static let pending = try! NSRegularExpression(
        pattern: #"\b(CI|checks?|pipeline|workflow run|GitHub Actions)\b[^.\n]{0,50}\b(running|pending|queued|in progress|re-?running|still going|kicked off)\b|\b(waiting|wait) (for|on) (the )?(CI|checks)\b|\bonce (CI|the checks?)\b|\bwhen (CI|the checks?) (finish|pass|go)"#,
        options: [.caseInsensitive])

    /// Whether the end of a reply says CI is still running. Reads the last 300 characters only.
    public static func mentionsPendingCI(_ reply: String) -> Bool {
        let tail = String(reply.suffix(300))
        return pending.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil
    }
}
