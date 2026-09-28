import Foundation

public struct AgentActivityFile: Identifiable, Sendable {
    public let path: String
    public let modified: Date
    public var id: String { path }
}

public struct AgentActivityFiles: Sendable {
    public let runtime: AgentRuntime
    public let root: String
    public let files: [AgentActivityFile]
    public let status: String
    public let partial: Bool

    /// Reads filenames and modification dates only. Never opens transcript bodies.
    public static func scan(runtime: AgentRuntime, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            maximumEntries: Int = 12_000) -> Self {
        let relative: String = switch runtime {
        case .codex: ".codex/sessions"
        case .claude: ".claude/projects"
        case .cursor: ".cursor/projects"
        case .devin: ".local/share/devin/cli/transcripts"
        case .grok: ".grok/sessions"
        }
        let root = home.appendingPathComponent(relative)
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            return Self(runtime: runtime, root: root.path, files: [], status: "No local activity folder found", partial: false)
        }
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return Self(runtime: runtime, root: root.path, files: [], status: "Linked activity root not scanned", partial: true)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var unreadable = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in unreadable = true; return true }) else {
            return Self(runtime: runtime, root: root.path, files: [], status: "Local activity folder is unreadable", partial: true)
        }
        let deadline = Date().addingTimeInterval(3)
        var files: [AgentActivityFile] = []
        var visited = 0
        var limited = false
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEntries || Date() > deadline || Task.isCancelled { limited = true; break }
            guard let values = try? url.resourceValues(forKeys: keys) else { unreadable = true; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if ["mcps", "canvases", "memory", "tool-results", "node_modules"].contains(url.lastPathComponent) || enumerator.level > 6 { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, let date = values.contentModificationDate else { continue }
            let accepted: Bool = switch runtime {
            case .codex, .claude: url.pathExtension == "jsonl"
            case .cursor: url.path.contains("/agent-transcripts/") && ["txt", "jsonl"].contains(url.pathExtension)
            case .devin: url.pathExtension == "json"
            case .grok: ["jsonl", "json"].contains(url.pathExtension) && url.lastPathComponent != "prompt_history.jsonl"
            }
            if accepted { files.append(AgentActivityFile(path: url.path, modified: date)) }
        }
        let recent = files.sorted { $0.modified > $1.modified }
        return Self(runtime: runtime, root: root.path, files: Array(recent.prefix(200)),
                    status: limited || unreadable ? "Partial local activity scan" : files.isEmpty ? "No matching activity files found" : "Local activity files found",
                    partial: limited || unreadable || files.count > 200)
    }
}
