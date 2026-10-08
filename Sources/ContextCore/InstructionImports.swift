import Foundation

/// Bounded, read-only resolution of Claude Code `@path` imports in instruction files.
/// Claude resolves relative paths against the importing file, expands `~/`, skips code
/// spans and fenced blocks, and follows imports recursively up to five hops.
public enum InstructionImports {
    public static let maximumDepth = 5
    public static let maximumBytes = 256 * 1_024
    /// Source label prefix for imported files added to a Claude startup estimate.
    public static let sourcePrefix = "Claude · Imported by "

    public enum Status: Sendable, Equatable {
        case found
        /// The file exists only under a different letter case. Resolution depends on the volume.
        case caseMismatch(actual: String)
        case missing
        /// A directory on the path could not be listed, so neither outcome is established.
        case unverified
    }

    public struct Reference: Sendable, Equatable {
        public let raw: String
        public let line: Int
        /// The path Claude would look up, before case correction.
        public let requestedPath: String
        /// The existing file's real path when found (with corrected case for a mismatch).
        public let actualPath: String?
        public let status: Status
    }

    public struct ImportedFile: Sendable, Equatable {
        public let path: String
        public let importer: String
        public let depth: Int
        public let bytes: Int64
        public let modified: Date
    }

    /// `@` tokens Claude treats as imports. Tokens must look like a file path so prose handles
    /// such as `@team` or scoped packages are not reported as missing files.
    static func importTokens(in text: String) -> [(raw: String, line: Int)] {
        var result: [(String, Int)] = []
        for (index, line) in proseLines(text) {
            var previous: Character = " "
            var current = line.startIndex
            while current < line.endIndex {
                let character = line[current]
                if character == "@", previous.isWhitespace {
                    let start = line.index(after: current)
                    let end = line[start...].firstIndex(where: \.isWhitespace) ?? line.endIndex
                    var token = String(line[start..<end])
                    while let last = token.last, ".,;:!?)]}\"'>".contains(last) { token.removeLast() }
                    if isPathLike(token) { result.append((token, index + 1)) }
                    current = end
                    previous = " "
                    continue
                }
                previous = character
                current = line.index(after: current)
            }
        }
        return result
    }

    /// Lines outside fenced code blocks, with inline code spans blanked.
    static func proseLines(_ text: String) -> [(Int, String)] {
        var output: [(Int, String)] = []
        var fence: String?
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            var blanked = ""
            var inCode = false
            for character in line {
                if character == "`" { inCode.toggle(); blanked.append(" "); continue }
                blanked.append(inCode ? " " : character)
            }
            output.append((index, blanked))
        }
        return output
    }

    static func isPathLike(_ token: String) -> Bool {
        guard !token.isEmpty, !token.contains("://"), !token.contains("@"),
              !token.contains("<"), !token.contains("{"), !token.contains("$") else { return false }
        if token.hasPrefix("~/") || token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") { return true }
        let name = token.split(separator: "/").last.map(String.init) ?? token
        return name.range(of: #"^[^.].*\.[A-Za-z][A-Za-z0-9]{0,9}$"#, options: .regularExpression) != nil
    }

    /// Resolves a path token the way Claude does: `~/` from home, absolute as given, otherwise
    /// relative to the directory of the file containing it.
    static func base(for raw: String, file: URL, home: URL) -> (URL, [String]) {
        if raw.hasPrefix("~/") { return (home, raw.dropFirst(2).split(separator: "/").map(String.init)) }
        if raw.hasPrefix("/") { return (URL(fileURLWithPath: "/"), raw.split(separator: "/").map(String.init)) }
        return (file.deletingLastPathComponent(), raw.split(separator: "/").map(String.init))
    }

    /// Case-aware lookup. On the default case-insensitive macOS volume a wrong-case path still
    /// opens, so each component is compared with the real directory entry.
    static func locate(_ raw: String, from file: URL, home: URL, listings: inout [String: [String]]) -> (requested: String, actual: String?, status: Status) {
        let (start, components) = base(for: raw, file: file, home: home)
        var requested = start, actual = start, mismatch = false
        for component in components where !component.isEmpty && component != "." {
            if component == ".." {
                requested.deleteLastPathComponent(); actual.deleteLastPathComponent(); continue
            }
            requested.appendPathComponent(component)
            let key = actual.path
            if listings[key] == nil { listings[key] = try? FileManager.default.contentsOfDirectory(atPath: key) }
            guard let names = listings[key] else {
                return (requested.path, nil, FileManager.default.fileExists(atPath: requested.path) ? .unverified : .missing)
            }
            if names.contains(component) {
                actual.appendPathComponent(component)
            } else if let real = names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                actual.appendPathComponent(real); mismatch = true
            } else {
                return (requested.path, nil, .missing)
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actual.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return (requested.path, nil, .missing)
        }
        return (requested.path, actual.standardizedFileURL.path, mismatch ? .caseMismatch(actual: actual.standardizedFileURL.path) : .found)
    }

    /// Bounded body read. Linked files are read through their resolved target.
    static func readText(_ url: URL) -> String? {
        try? BoundedTextReader.read(url: url.resolvingSymlinksInPath(), maximumBytes: maximumBytes)
    }

    public static func references(in file: URL, text: String, home: URL) -> [Reference] {
        var listings: [String: [String]] = [:]
        return importTokens(in: text).map { token in
            let located = locate(token.raw, from: file, home: home, listings: &listings)
            return Reference(raw: token.raw, line: token.line, requestedPath: located.requested,
                             actualPath: located.actual, status: located.status)
        }
    }

    /// Files reachable from `root` through imports, excluding `root`, at most five hops deep.
    /// Unreadable or oversized files contribute no further imports.
    public static func closure(of root: URL, home: URL, allows: (URL) -> Bool = { _ in true }) -> [ImportedFile] {
        var result: [ImportedFile] = []
        var visited: Set<String> = [canonical(root.path)]
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (file, depth) = queue.removeFirst()
            guard depth < maximumDepth, allows(file), let text = readText(file) else { continue }
            for reference in references(in: file, text: text, home: home) {
                guard let path = reference.actualPath else { continue }
                let url = URL(fileURLWithPath: path)
                guard allows(url), visited.insert(canonical(path)).inserted else { continue }
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
                result.append(ImportedFile(path: path, importer: file.path, depth: depth + 1,
                    bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                    modified: attributes?[.modificationDate] as? Date ?? .distantPast))
                queue.append((url, depth + 1))
            }
        }
        return result
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Memoizes import closures during one ranking pass.
final class InstructionImportCache {
    private var closures: [String: [InstructionImports.ImportedFile]] = [:]
    let home: URL
    let allows: (URL) -> Bool
    init(home: URL, allows: @escaping (URL) -> Bool) { self.home = home; self.allows = allows }
    func closure(_ path: String) -> [InstructionImports.ImportedFile] {
        if let cached = closures[path] { return cached }
        let value = InstructionImports.closure(of: URL(fileURLWithPath: path), home: home, allows: allows)
        closures[path] = value
        return value
    }
}
