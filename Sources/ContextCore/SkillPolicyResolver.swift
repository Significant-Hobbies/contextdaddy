import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SkillPolicyResolver {
    public static func resolve(report: AIContextDiscoveryReport) -> SkillCatalogSnapshot {
        let groups = Dictionary(grouping: report.items.filter { $0.kind == .skill }) {
            $0.resolvedPath ?? $0.path
        }
        var records = groups.compactMap { physicalPath, items in
            makeRecord(physicalPath: physicalPath, items: items)
        }
        records = resolvePrecedence(records)
        let recordsByName = Dictionary(grouping: records, by: { $0.name.lowercased() })
        records = records.map { record in
            var record = record
            let activeRuntimes = Set(record.exposedRuntimes)
            let overlapping = recordsByName[record.name.lowercased(), default: []].filter { candidate in
                candidate.id == record.id || !activeRuntimes.isDisjoint(with: candidate.exposedRuntimes)
            }
            record.definitionConflictCount = max(1, overlapping.count)
            return record
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return SkillCatalogSnapshot(records: records, coverage: report.coverage, generatedAt: Date())
    }

    private static func resolvePrecedence(_ records: [SkillRecord]) -> [SkillRecord] {
        let byName = Dictionary(grouping: records, by: { $0.name.lowercased() })
        return records.map { original in
            var record = original
            record.policies = original.policies.map { policy in
                let peers = byName[record.name.lowercased(), default: []].filter { $0.policy(for: policy.runtime)?.isExposed == true }
                guard policy.isExposed, peers.count > 1 else { return policy }
                var state = SkillPrecedence.State.unverified
                var preferred: String?
                var source = "No qualified winner rule for this runtime or these routes."
                var reason = "Same-name precedence is unverified; no winner was inferred from scan order."
                // The inventory can contain legacy or malformed names even though
                // the shared skill-name convention is lowercase. Never infer a
                // winner across case-only variants of one apparent name.
                if Set(peers.map(\.name)).count > 1 {
                    reason = "Case-only name collision is unverified; no winner was inferred."
                }
                // Scope is not enough: recognize only direct skill-directory routes,
                // excluding nested/custom roots, plugin namespaces and renamed frontmatter.
                func routes(_ item: SkillRecord) -> [SkillExposure] {
                    item.exposures.filter { $0.provider == .claude && $0.applicability != .installedOnly }
                }
                func ordinary(_ item: SkillRecord) -> Bool {
                    let exposures = routes(item)
                    return !exposures.isEmpty && exposures.allSatisfy {
                        $0.logicalPath.hasSuffix("/.claude/skills/\(item.name)/SKILL.md") &&
                        (($0.scope == .global && $0.source == "Claude · Personal skills") || $0.scope == .project)
                    }
                }
                if Set(peers.map(\.name)).count == 1, policy.runtime == .claude, peers.allSatisfy(ordinary) {
                    let personal = peers.filter { routes($0).contains { $0.scope == .global } }
                    if personal.count == 1, let winner = personal.first {
                        preferred = winner.id
                        state = record.id == winner.id ? .preferred : .shadowed
                        source = "https://code.claude.com/docs/en/skills#resolve-skills-that-share-a-name"
                        reason = state == .shadowed
                            ? "Shadowed among discovered Claude routes by personal definition \(winner.id). Personal skills override project skills."
                            : "Preferred among discovered Claude routes: personal skills override project skills."
                        reason += " Enterprise, synced skills and session overrides were not qualified; runtime activation remains unverified."
                    }
                } else if Set(peers.map(\.name)).count == 1, policy.runtime == .codex, peers.allSatisfy({ item in
                    item.exposures.filter { [.codex, .agents].contains($0.provider) && $0.applicability != .installedOnly }
                        .allSatisfy { $0.logicalPath.contains("/.agents/skills/") }
                }) {
                    state = .coexisting
                    source = "https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills"
                    reason = "Codex can list both same-name skills; these discovered routes have no exclusive winner. Runtime activation remains unverified."
                }
                return SkillRuntimePolicy(runtime: policy.runtime,
                    mode: state == .shadowed || state == .unverified ? .unverified : policy.mode,
                    explicit: state == .shadowed || state == .unverified ? false : policy.explicit,
                    reason: policy.reason + " " + reason, invocation: policy.invocation,
                    isExposed: policy.isExposed, desiredMode: policy.desiredMode,
                    precedence: SkillPrecedence(state: state, preferredDefinitionID: preferred, source: source))
            }
            return record
        }
    }

    private static func makeRecord(physicalPath: String, items: [AIContextItem]) -> SkillRecord? {
        guard let first = items.sorted(by: { $0.path < $1.path }).first else { return nil }
        let document = readDocument(at: URL(fileURLWithPath: physicalPath))
        let metadata = document.metadata
        let name = metadata.name ?? first.name
        let exposures = items.map {
            SkillExposure(
                logicalPath: $0.path,
                resolvedPath: $0.resolvedPath ?? $0.path,
                source: $0.source,
                scope: $0.scope,
                provider: $0.provider,
                applicability: $0.applicability
            )
        }.sorted { $0.logicalPath < $1.logicalPath }
        let activeProviders = Set(exposures.filter { $0.applicability != .installedOnly }.map(\.provider))
        let installedProviders = Set(exposures.filter { $0.applicability == .installedOnly }.map(\.provider))
        let policies = AgentRuntime.allCases.map {
            policy(
                for: $0,
                name: name,
                physicalPath: physicalPath,
                metadata: metadata,
                documentReadable: document.fingerprint != nil,
                activeProviders: activeProviders,
                installedProviders: installedProviders
            )
        }
        return SkillRecord(
            id: physicalPath,
            name: name,
            description: metadata.description ?? "No description declared.",
            logicalBytes: first.logicalBytes,
            modified: first.modified,
            exposures: exposures,
            policies: policies,
            contentFingerprint: document.fingerprint
        )
    }

    private static func policy(
        for runtime: AgentRuntime,
        name: String,
        physicalPath: String,
        metadata: Frontmatter,
        documentReadable: Bool,
        activeProviders: Set<AIContextProvider>,
        installedProviders: Set<AIContextProvider>
    ) -> SkillRuntimePolicy {
        let invocation = switch runtime {
        case .codex: "$\(name)"
        case .claude, .cursor, .grok, .devin: "/\(name)"
        }
        let exposed = providers(activeProviders, expose: runtime)
        guard exposed else {
            let cachedOnly = providers(installedProviders, expose: runtime)
            return SkillRuntimePolicy(
                runtime: runtime,
                mode: .unsupported,
                explicit: true,
                reason: cachedOnly
                    ? "An installed cache copy was found, but no active skill exposure for this runtime was discovered."
                    : "No skill exposure for this runtime was discovered.",
                invocation: invocation,
                isExposed: false
            )
        }

        guard documentReadable else {
            return SkillRuntimePolicy(runtime: runtime, mode: .unverified, explicit: false,
                reason: "SKILL.md could not be read within the 64 KiB safety bound; invocation controls are unavailable.",
                invocation: invocation)
        }

        if runtime == .codex {
            switch codexImplicitPolicy(skillPath: physicalPath) {
            case .value(let implicit):
                return SkillRuntimePolicy(runtime: runtime, mode: implicit ? .automatic : .manualOnly, explicit: true,
                    reason: implicit ? "agents/openai.yaml allows implicit invocation." : "agents/openai.yaml disables implicit invocation.", invocation: invocation)
            case .unverified:
                return SkillRuntimePolicy(runtime: runtime, mode: .unverified, explicit: false,
                    reason: "The Codex policy file could not be safely resolved. Review agents/openai.yaml.", invocation: invocation)
            case .unspecified:
                return SkillRuntimePolicy(runtime: runtime, mode: .automatic, explicit: false,
                    reason: "Codex defaults to implicit invocation. SKILL.md invocation flags for other agents do not disable it; use agents/openai.yaml.", invocation: invocation,
                    desiredMode: metadata.disableModelInvocation == true ? .manualOnly : nil)
            }
        }

        if runtime == .devin {
            let triggers = Set((metadata.triggers ?? ["user", "model"]).map { $0.lowercased() })
            let mode: InvocationMode = triggers == ["user"] ? .manualOnly : triggers == ["model"] ? .modelOnly : triggers == ["user", "model"] ? .automatic : .unverified
            return SkillRuntimePolicy(runtime: runtime, mode: mode, explicit: metadata.triggers != nil,
                                      reason: metadata.triggers == nil ? "Devin defaults to user and model triggers." : "Devin invocation follows its triggers list; other agents’ frontmatter controls are separate.", invocation: invocation)
        }
        if runtime == .grok, let raw = metadata.rawUserInvocable, raw != "true" {
            return SkillRuntimePolicy(runtime: runtime, mode: .disabled, explicit: true,
                                      reason: "Grok hides this skill from both user and model because user-invocable is not literal true.", invocation: invocation)
        }
        if runtime == .claude, metadata.disableModelInvocation == true, metadata.userInvocable == false {
            return SkillRuntimePolicy(runtime: runtime, mode: .disabled, explicit: true,
                reason: "SKILL.md disables both model invocation and direct user invocation.",
                invocation: invocation, desiredMode: .disabled)
        }
        if metadata.disableModelInvocation == true {
            return SkillRuntimePolicy(
                runtime: runtime,
                mode: .manualOnly,
                explicit: true,
                reason: "SKILL.md disables model invocation.",
                invocation: invocation,
                desiredMode: .manualOnly
            )
        }
        if metadata.userInvocable == false {
            return SkillRuntimePolicy(
                runtime: runtime,
                mode: .modelOnly,
                explicit: true,
                reason: "SKILL.md disables direct user invocation.",
                invocation: invocation,
                desiredMode: .modelOnly
            )
        }
        return SkillRuntimePolicy(
            runtime: runtime,
            mode: .automatic,
            explicit: false,
            reason: "No portable restriction was found; runtime default is assumed.",
            invocation: invocation
        )
    }

    private static func providers(_ providers: Set<AIContextProvider>, expose runtime: AgentRuntime) -> Bool {
        switch runtime {
        case .codex: providers.contains(.codex) || providers.contains(.agents)
        case .claude: providers.contains(.claude)
        case .cursor: providers.contains(.cursor)
        case .devin: providers.contains(.devin)
        case .grok: providers.contains(.grok)
        }
    }

    private enum CodexPolicy { case value(Bool), unspecified, unverified }
    private static func codexImplicitPolicy(skillPath: String) -> CodexPolicy {
        let url = URL(fileURLWithPath: skillPath).deletingLastPathComponent().appendingPathComponent("agents/openai.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return .unspecified }
        guard let text = try? BoundedTextReader.read(url: url.resolvingSymlinksInPath(), maximumBytes: 64 * 1024) else { return .unverified }
        let lines = text.components(separatedBy: "\n").map(stripYAMLComment)
        guard !text.contains("<<:"), !text.contains("\t") else { return .unverified }
        let policies = lines.indices.filter { lines[$0].hasPrefix("policy:") }
        guard policies.count <= 1 else { return .unverified }
        guard let start = policies.first else { return text.contains("allow_implicit_invocation") ? .unverified : .unspecified }
        guard lines[start].trimmingCharacters(in: .whitespaces) == "policy:" else { return .unverified }
        let end = lines.indices.dropFirst(start + 1).first { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty && !lines[$0].hasPrefix(" ") } ?? lines.count
        let values = lines[(start + 1)..<end].filter { $0.hasPrefix("  allow_implicit_invocation:") }
        guard values.count <= 1 else { return .unverified }
        guard let value = values.first else { return .unspecified }
        switch value.dropFirst("  allow_implicit_invocation:".count).trimmingCharacters(in: .whitespaces) {
        case "true": return .value(true)
        case "false": return .value(false)
        default: return .unverified
        }
    }

    private static func readDocument(at url: URL) -> SkillDocumentMetadata {
        guard let text = try? BoundedTextReader.read(url: url.resolvingSymlinksInPath(), maximumBytes: 64 * 1024) else {
            return SkillDocumentMetadata(metadata: Frontmatter(), fingerprint: nil)
        }
        return SkillDocumentMetadata(
            metadata: readMetadata(text: text),
            fingerprint: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        )
    }

    static func readMetadata(text: String) -> Frontmatter {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return Frontmatter()
        }
        var metadata = Frontmatter()
        var inTriggers = false
        var collectingDescription = false
        for line in lines.dropFirst() {
            let trimmed = stripYAMLComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            if collectingDescription, line.hasPrefix(" ") || line.hasPrefix("\t") {
                if !trimmed.isEmpty {
                    metadata.description = [metadata.description, trimmed].compactMap { $0 }.joined(separator: " ")
                }
                continue
            }
            collectingDescription = false
            if trimmed.hasPrefix("name:") {
                metadata.name = scalar(after: "name:", in: trimmed)
                inTriggers = false
            } else if trimmed.hasPrefix("description:") {
                let description = scalar(after: "description:", in: trimmed)
                if description == ">" || description == "|" {
                    metadata.description = nil
                    collectingDescription = true
                } else {
                    metadata.description = description
                }
                inTriggers = false
            } else if trimmed.hasPrefix("disable-model-invocation:") {
                metadata.disableModelInvocation = parseBool(scalar(after: "disable-model-invocation:", in: trimmed))
                inTriggers = false
            } else if trimmed.hasPrefix("user-invocable:") {
                metadata.rawUserInvocable = String(trimmed.dropFirst("user-invocable:".count)).trimmingCharacters(in: .whitespaces)
                metadata.userInvocable = parseBool(metadata.rawUserInvocable ?? "")
                inTriggers = false
            } else if trimmed.hasPrefix("triggers:") {
                inTriggers = true
                let inline = scalar(after: "triggers:", in: trimmed)
                if inline.hasPrefix("[") {
                    metadata.triggers = inline.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { cleanScalar(String($0)) }
                    inTriggers = false
                }
            } else if inTriggers, trimmed.hasPrefix("-") {
                metadata.triggers = (metadata.triggers ?? []) + [cleanScalar(String(trimmed.dropFirst()))]
            } else if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTriggers = false
            }
        }
        return metadata
    }

    private static func stripYAMLComment(_ line: String) -> String {
        var quote: Character?, escaped = false
        for index in line.indices {
            let c = line[index]
            if let current = quote {
                if c == current && !escaped { quote = nil }
                escaped = current == "\"" && c == "\\" && !escaped
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "#", index == line.startIndex || line[line.index(before: index)].isWhitespace { return String(line[..<index]) }
        }
        return line
    }

    private static func scalar(after key: String, in line: String) -> String {
        cleanScalar(String(line.dropFirst(key.count)))
    }

    private static func cleanScalar(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch cleanScalar(value).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}

struct Frontmatter {
    var name: String?
    var description: String?
    var disableModelInvocation: Bool?
    var rawUserInvocable: String?
    var userInvocable: Bool?
    var triggers: [String]?
}

private struct SkillDocumentMetadata {
    let metadata: Frontmatter
    let fingerprint: String?
}

enum BoundedTextReader {
    static func read(url: URL, maximumBytes: Int) throws -> String {
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw SkillDocumentReadError.unreadable
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SkillDocumentReadError.unreadable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else {
            throw SkillDocumentReadError.changedDuringRead
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress?.advanced(by: count), buffer.count - count)
                #else
                Glibc.read(descriptor, buffer.baseAddress?.advanced(by: count), buffer.count - count)
                #endif
            }
            if amount > 0 { count += amount }
            else if amount == 0 { break }
            else if errno != EINTR { throw SkillDocumentReadError.unreadable }
        }
        guard count <= maximumBytes else { throw SkillDocumentReadError.unreadable }
        let data = Data(bytes.prefix(count))
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw SkillDocumentReadError.unreadable
        }
        return text
    }
}
