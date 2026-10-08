import Foundation

/// Deterministic, read-only checks of instruction imports, skill metadata, skill links and
/// memory index sizes. Reads at most 256 KiB of each instruction or skill document, never
/// retains bodies in findings, and reports measured file sizes rather than loaded context.
public enum InstructionHygieneAudit {
    public struct Thresholds: Sendable {
        public var claudeMemoryIndexBytes = 24 * 1_024
        public var claudeMemoryIndexLines = 200
        public var codexMemorySummaryBytes = 8 * 1_024
        public var codexMemoryBytes = 250 * 1_024
        public var maximumProjects = 1_000
        public var maximumSkills = 5_000
        public init() {}
    }

    static let autoTriggerPhrases = [
        "trigger automatically", "triggers automatically", "auto-trigger", "do not wait for the user",
        "don't wait for the user", "when in doubt", "always use this skill",
    ]
    static let ruleFileNames: Set<String> = ["agents.md", "agents.override.md", "claude.md", "claude.local.md", "gemini.md"]

    public static func audit(home: URL, projects: [URL], thresholds: Thresholds = .init()) -> (issues: [ConfigurationHealthIssue], files: [ConfigurationFileCheck]) {
        var auditor = Auditor(home: home.standardizedFileURL, thresholds: thresholds)
        let homePath = home.standardizedFileURL.path
        var seenProjects = Set<String>()
        let projectRoots = projects.map(\.standardizedFileURL).filter {
            $0.path != homePath && seenProjects.insert($0.path).inserted
        }.prefix(thresholds.maximumProjects)

        let globalVisible = auditor.claudeRoots([home.appendingPathComponent(".claude/CLAUDE.md")])
        auditor.unimportedReferences(visible: globalVisible)
        var allLoaded = auditor.loaded
        for project in projectRoots {
            auditor.loaded = []
            let visible = globalVisible.union(auditor.claudeRoots(["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].map { project.appendingPathComponent($0) }))
            auditor.unimportedReferences(visible: visible)
            auditor.agentsVisibility(project: project, visible: visible)
            allLoaded += auditor.loaded
        }
        auditor.loaded = allLoaded

        let skillFolders: [(String, AgentRuntime)] = [(".claude/skills", .claude), (".codex/skills", .codex), (".agents/skills", .codex)]
        var skillRoots: [(URL, AgentRuntime)] = []
        for base in [home] + Array(projectRoots) {
            skillRoots += skillFolders.map { (base.appendingPathComponent($0.0), $0.1) }
        }
        for (root, runtime) in skillRoots { auditor.skills(root: root, runtime: runtime) }
        auditor.disabledSkillMentions()
        auditor.memory()

        var unique = Set<String>()
        let issues = auditor.issues.filter { unique.insert($0.id).inserted }
        var uniqueFiles = Set<String>()
        let files = auditor.files.filter { uniqueFiles.insert($0.id).inserted }
        return (issues, files)
    }

    private struct Auditor {
        let home: URL
        let thresholds: Thresholds
        var issues: [ConfigurationHealthIssue] = []
        var files: [ConfigurationFileCheck] = []
        /// Claude-loaded instruction files read in the current pass.
        var loaded: [(URL, String)] = []
        var checkedImports = Set<String>()
        var disabledSkills: [String: String] = [:]
        var skillCount = 0

        mutating func add(_ severity: ConfigurationIssueSeverity, _ runtime: AgentRuntime, _ key: String, _ title: String,
                          _ detail: String, _ path: String, _ line: Int, _ remediation: String) {
            issues.append(.init(id: "\(runtime.rawValue)-hygiene-\(key)-\(path):\(line)", severity: severity, runtime: runtime,
                                title: title, detail: detail, path: path, line: line, remediation: remediation))
        }

        /// Reads each existing root and its import closure. Returns canonical paths Claude can see.
        mutating func claudeRoots(_ roots: [URL]) -> Set<String> {
            var visible = Set<String>()
            var queue: [(URL, Int)] = roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0, 0) }
            var visited = Set<String>()
            while !queue.isEmpty {
                let (file, depth) = queue.removeFirst()
                let canonical = InstructionImports.canonical(file.path)
                guard visited.insert(canonical).inserted else { continue }
                visible.insert(canonical)
                guard let text = InstructionImports.readText(file) else {
                    files.append(.init(runtime: .claude, path: file.path, status: .unverified, detail: "Unreadable, non-UTF-8 or above 256 KiB; imports were not checked."))
                    continue
                }
                loaded.append((file, text))
                files.append(.init(runtime: .claude, path: file.path, status: .checked, detail: "@imports (up to \(InstructionImports.maximumDepth) hops), referenced instruction files and Skill tool mentions."))
                let report = checkedImports.insert(canonical).inserted
                for reference in InstructionImports.references(in: file, text: text, home: home) {
                    switch reference.status {
                    case .missing where report:
                        add(.error, .claude, "import-missing-\(reference.raw)", "Import target not found",
                            "`@\(reference.raw)` resolves to \(reference.requestedPath), which does not exist. Claude skips missing imports without an error, so these instructions never load.",
                            file.path, reference.line, "Correct the path or remove the import. Relative imports resolve from this file's folder; `~/` resolves from home.")
                    case .caseMismatch(let actual) where report:
                        add(.warning, .claude, "import-case-\(reference.raw)", "Import case differs from the file name",
                            "`@\(reference.raw)` only matches \(actual) because this volume ignores letter case. It will not resolve on a case-sensitive volume or another OS.",
                            file.path, reference.line, "Change the import to `@\(URL(fileURLWithPath: actual).lastPathComponent)` with the file's exact case.")
                    default: break
                    }
                    if let actual = reference.actualPath, depth + 1 <= InstructionImports.maximumDepth {
                        queue.append((URL(fileURLWithPath: actual), depth + 1))
                    }
                }
            }
            return visible
        }

        /// Prose that points at another instruction file which no Claude-loaded file imports.
        mutating func unimportedReferences(visible: Set<String>) {
            for (file, text) in loaded {
                for (index, line) in InstructionImports.proseLines(text) + codeSpanLines(text) {
                    for raw in mentionedPaths(in: line) {
                        let target: URL
                        if raw.hasPrefix("~/") { target = home.appendingPathComponent(String(raw.dropFirst(2))) }
                        else if raw.hasPrefix("/") { target = URL(fileURLWithPath: raw) }
                        else { target = file.deletingLastPathComponent().appendingPathComponent(raw) }
                        let name = target.lastPathComponent.lowercased()
                        guard InstructionHygieneAudit.ruleFileNames.contains(name) || target.pathComponents.contains("rules") else { continue }
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                        let canonical = InstructionImports.canonical(target.path)
                        guard canonical != InstructionImports.canonical(file.path), !visible.contains(canonical) else { continue }
                        add(.warning, .claude, "unimported-\(raw)", "Referenced instructions are not imported",
                            "This file mentions \(raw) without an `@` import, and no loaded Claude instruction imports it. Claude only sees that file if it decides to open it. This is a text-pattern match; confirm the intent.",
                            file.path, index + 1, "If Claude should always follow \(raw), import it with `@\(raw)`. Otherwise leave it as a plain reference.")
                    }
                }
            }
        }

        /// Path mentions inside inline code also count as prose references; fences do not.
        func codeSpanLines(_ text: String) -> [(Int, String)] {
            let prose = Set(InstructionImports.proseLines(text).map(\.0))
            return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
                guard prose.contains(index), raw.contains("`") else { return nil }
                var spans = "", inCode = false
                for character in raw {
                    if character == "`" { inCode.toggle(); spans.append(" "); continue }
                    spans.append(inCode ? character : " ")
                }
                return (index, spans)
            }
        }

        func mentionedPaths(in line: String) -> [String] {
            let pattern = #"(~/|/|\.\.?/)?([A-Za-z0-9_.\-]+/)+[A-Za-z0-9_.\-]+\.md\b"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(line.startIndex..., in: line)
            return expression.matches(in: line, range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: line) else { return nil }
                if swiftRange.lowerBound > line.startIndex {
                    let before = line[line.index(before: swiftRange.lowerBound)]
                    // `@path` is an import; any other attached character is part of a URL or word.
                    guard before.isWhitespace || "(\"'[*".contains(before) else { return nil }
                }
                return String(line[swiftRange])
            }
        }

        mutating func agentsVisibility(project: URL, visible: Set<String>) {
            let agents = project.appendingPathComponent("AGENTS.md")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: agents.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !visible.contains(InstructionImports.canonical(agents.path)) else { return }
            let hasClaude = FileManager.default.fileExists(atPath: project.appendingPathComponent("CLAUDE.md").path)
                || FileManager.default.fileExists(atPath: project.appendingPathComponent(".claude/CLAUDE.md").path)
            files.append(.init(runtime: .claude, path: agents.path, status: .checked, detail: "Claude visibility of project AGENTS.md."))
            add(.warning, .claude, "agents-invisible", "Project AGENTS.md is not visible to Claude",
                hasClaude ? "This project has CLAUDE.md, but neither it nor its imports include AGENTS.md. Claude Code does not read AGENTS.md on its own."
                          : "This project has AGENTS.md and no CLAUDE.md. Claude Code does not read AGENTS.md on its own, so these rules reach Codex only.",
                agents.path, 1, hasClaude ? "Add `@AGENTS.md` to the project CLAUDE.md if both agents should follow the same rules." : "Create a CLAUDE.md containing `@AGENTS.md` if Claude should follow the same rules.")
        }

        mutating func skills(root: URL, runtime: AgentRuntime) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            var broken: [String] = []
            var checked = 0
            func walk(_ folder: URL, depth: Int) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
                for name in names.sorted() where skillCount < thresholds.maximumSkills {
                    let child = folder.appendingPathComponent(name)
                    var info = stat()
                    guard lstat(child.path, &info) == 0 else { continue }
                    let isLink = (info.st_mode & S_IFMT) == S_IFLNK
                    var childIsDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory)
                    if isLink && !exists { broken.append(depth == 0 ? name : folder.lastPathComponent + "/" + name); continue }
                    guard exists, childIsDirectory.boolValue else { continue }
                    let document = child.appendingPathComponent("SKILL.md")
                    if FileManager.default.fileExists(atPath: document.path) {
                        skillCount += 1; checked += 1
                        skill(document, folderName: name, runtime: runtime)
                    } else if depth == 0 {
                        walk(child, depth: 1)
                    }
                }
            }
            walk(root, depth: 0)
            files.append(.init(runtime: runtime, path: root.path, status: .checked,
                               detail: "\(checked) skill \(checked == 1 ? "definition" : "definitions") (description and invocation metadata) · \(broken.count) broken \(broken.count == 1 ? "link" : "links")."))
            guard !broken.isEmpty else { return }
            let listed = broken.prefix(25).joined(separator: ", ") + (broken.count > 25 ? " and \(broken.count - 25) more" : "")
            add(.warning, runtime, "broken-skill-links", "\(broken.count) broken skill \(broken.count == 1 ? "link" : "links")",
                "Links whose targets no longer exist: \(listed). Agents skip them, so these skills are unavailable.",
                root.path, 1, "Repoint each link to the skill's current source, or remove the dead link after confirming the source was retired.")
        }

        var checkedSkills = Set<String>()
        mutating func skill(_ document: URL, folderName: String, runtime: AgentRuntime) {
            guard checkedSkills.insert(InstructionImports.canonical(document.path)).inserted else { return }
            guard let text = InstructionImports.readText(document) else {
                files.append(.init(runtime: runtime, path: document.path, status: .unverified, detail: "Skill document unreadable or above 256 KiB."))
                return
            }
            let metadata = SkillPolicyResolver.readMetadata(text: text)
            let name = metadata.name?.isEmpty == false ? metadata.name! : folderName
            if metadata.disableModelInvocation == true {
                if runtime == .claude { disabledSkills[name] = document.path }
                return
            }
            let description = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if description.isEmpty {
                add(.error, runtime, "skill-description", "Skill has no description",
                    "`\(name)` can be invoked by the model, but its frontmatter has an empty or missing description. The model selects skills by description, so it cannot choose this one reliably.",
                    document.path, 1, "Add a one-sentence `description:` that says what the skill does and when to use it, or set `disable-model-invocation: true` if it is manual only.")
                return
            }
            let lower = description.lowercased()
            if let phrase = InstructionHygieneAudit.autoTriggerPhrases.first(where: { lower.contains($0) }) {
                add(.warning, runtime, "skill-autotrigger", "Skill description asks to trigger broadly",
                    "`\(name)`'s description contains \"\(phrase)\". Language like this can make the model invoke the skill on unrelated tasks.",
                    document.path, 1, "Describe the specific situations the skill is for instead of instructing the model to use it by default.")
            }
        }

        /// Instructions that tell Claude to use the Skill tool for a skill it cannot invoke.
        mutating func disabledSkillMentions() {
            guard !disabledSkills.isEmpty else { return }
            var reported = Set<String>()
            for (file, text) in loaded {
                for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let line = String(raw)
                    guard line.range(of: "skill tool", options: .caseInsensitive) != nil else { continue }
                    for (name, path) in disabledSkills.sorted(by: { $0.key < $1.key }) {
                        let escaped = NSRegularExpression.escapedPattern(for: name)
                        let pattern = #"(skill:\s*["'`]?|["'`/])"# + escaped + #"(["'`]|\b)"#
                        guard line.range(of: pattern, options: .regularExpression) != nil,
                              reported.insert("\(file.path):\(index):\(name)").inserted else { continue }
                        add(.error, .claude, "disabled-skill-\(name)", "Instruction invokes a skill the model cannot use",
                            "This line tells Claude to invoke `\(name)` through the Skill tool, but \(path) sets `disable-model-invocation: true`. The tool call is refused, so the instruction cannot be followed.",
                            file.path, index + 1, "Either remove `disable-model-invocation: true` from the skill or change the instruction to ask the user to run `/\(name)`.")
                    }
                }
            }
        }

        mutating func memory() {
            let manager = FileManager.default
            let projects = home.appendingPathComponent(".claude/projects")
            if let stores = try? manager.contentsOfDirectory(atPath: projects.path) {
                for store in stores.sorted().prefix(500) {
                    let index = projects.appendingPathComponent(store).appendingPathComponent("memory/MEMORY.md")
                    guard let (bytes, lines) = measure(index, countLines: true) else { continue }
                    files.append(.init(runtime: .claude, path: index.path, status: .checked, detail: "Memory index size: \(bytes) bytes, \(lines ?? 0) lines."))
                    let overBytes = bytes > thresholds.claudeMemoryIndexBytes
                    let overLines = (lines ?? 0) > thresholds.claudeMemoryIndexLines
                    guard overBytes || overLines else { continue }
                    add(.warning, .claude, "memory-index", "Memory index exceeds Claude's startup limit",
                        "Measured \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) (\(bytes) bytes) and \(lines ?? 0) lines. Claude Code truncates the MEMORY.md index past \(thresholds.claudeMemoryIndexLines) lines or about \(thresholds.claudeMemoryIndexBytes / 1_024) KB, so later entries are cut from the startup index. Whether a given session loaded this store is not verified.",
                        index.path, 1, "Move detail into topic files and keep MEMORY.md to one short pointer line per entry.")
                }
            }
            let codex = home.appendingPathComponent(".codex/memories")
            for (name, limit, key) in [("memory_summary.md", thresholds.codexMemorySummaryBytes, "codex-summary"), ("MEMORY.md", thresholds.codexMemoryBytes, "codex-memory")] {
                let file = codex.appendingPathComponent(name)
                guard let (bytes, _) = measure(file, countLines: false) else { continue }
                files.append(.init(runtime: .codex, path: file.path, status: .checked, detail: "Memory size: \(bytes) bytes."))
                guard bytes > limit else { continue }
                add(.warning, .codex, key, "Codex memory file is large",
                    "Measured \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) (\(bytes) bytes), above the \(limit / 1_024) KB review threshold. Size only; what Codex loads from it is not verified.",
                    file.path, 1, "Prune dated task logs and duplicated entries through Codex's own memory controls.")
            }
        }

        /// Regular, unlinked files only. Line counting reads at most 8 MiB and keeps no text.
        func measure(_ url: URL, countLines: Bool) -> (Int, Int?)? {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let bytes = Int(info.st_size)
            guard countLines, bytes <= 8 * 1_024 * 1_024, let handle = try? FileHandle(forReadingFrom: url) else { return (bytes, nil) }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: bytes) else { return (bytes, nil) }
            var lines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            if let last = data.last, last != 0x0A { lines += 1 }
            return (bytes, lines)
        }
    }
}
