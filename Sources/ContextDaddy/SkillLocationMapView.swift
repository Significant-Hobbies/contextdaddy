import ContextCore
import SwiftUI

/// Routes come from the scoped catalog. A route is not another physical copy.
struct SkillLocationMapView: View {
    let records: [SkillRecord]
    let onSelect: (String, Set<String>) -> Void
    let onReviewCopies: (Set<String>) -> Void
    @State private var page = 0
    @State private var routeLimits: [String: Int] = [:]

    private struct Route: Identifiable {
        let skill: SkillRecord
        let exposure: SkillExposure
        var id: String { skill.id + exposure.logicalPath }
    }
    private struct Location: Identifiable {
        let id: String
        let routes: [Route]
        var sourceIDs: Set<String> { Set(routes.map { $0.skill.id }) }
        var redirected: Int { routes.filter { $0.exposure.logicalPath != $0.exposure.resolvedPath }.count }
    }
    private var locations: [Location] {
        let routes = records.flatMap { skill in skill.exposures.map { Route(skill: skill, exposure: $0) } }
        return Dictionary(grouping: routes) { route in
            let path = route.exposure.logicalPath
            if let range = path.range(of: "/skills/") { return String(path[..<range.upperBound].dropLast()) }
            return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().path
        }.map { Location(id: $0.key, routes: $0.value.sorted { $0.skill.name < $1.skill.name }) }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        let groups = locations
        let matchingIDs = Set(Dictionary(grouping: records.filter { $0.contentFingerprint != nil }, by: { $0.contentFingerprint! })
            .values.filter { Set($0.map(\.id)).count > 1 }.flatMap { $0.map(\.id) })
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where these skills come from").font(.headline)
                Text("Expand a folder to trace its entries to stored files. Linked routes can share one source; they are not extra copies.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                if groups.isEmpty {
                    Text("No skill locations found in this scan. Add a search location from More.").font(.caption)
                }
                ForEach(Array(groups.dropFirst(page * 5).prefix(5))) { group in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Show these \(group.sourceIDs.count) sources in the library") { onSelect(group.id, group.sourceIDs) }
                            let copyIDs = SkillInventoryAnswers.matchingCopyIDs(near: group.sourceIDs, records: records)
                            if !copyIDs.isEmpty {
                                Button("Compare matching copies across locations (\(copyIDs.count) sources)") { onReviewCopies(copyIDs) }
                            }
                            ForEach(Array(group.routes.prefix(routeLimits[group.id, default: 8]))) { route in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(route.skill.name).font(.caption.weight(.semibold))
                                    Text("\(route.exposure.scope.rawValue) · \(route.exposure.provider.rawValue) · \(route.skill.ownership.rawValue)")
                                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                                    Text("Available to: " + (route.skill.exposedRuntimes.isEmpty ? "no known agent" : route.skill.exposedRuntimes.map(\.rawValue).joined(separator: ", ")))
                                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                                    Text(short(route.exposure.logicalPath)).font(.caption2.monospaced())
                                    if route.exposure.logicalPath != route.exposure.resolvedPath {
                                        Label(short(route.exposure.resolvedPath), systemImage: "arrow.turn.down.right")
                                            .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.blue)
                                    }
                                }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            if group.routes.count > routeLimits[group.id, default: 8] {
                                Button("Show more entries (\(group.routes.count - routeLimits[group.id, default: 8]) remaining)") { routeLimits[group.id, default: 8] += 8 }
                            }
                        }.padding(.top, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(short(group.id)).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
                            Text("\(group.routes.count) routes → \(group.sourceIDs.count) physical sources · \(group.redirected) redirected paths")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                            if !group.sourceIDs.intersection(matchingIDs).isEmpty {
                                Text("Matching instructions elsewhere: \(group.sourceIDs.intersection(matchingIDs).count) sources · review before merging")
                                    .font(.caption).foregroundStyle(DaddyTheme.amber)
                            }
                        }
                    }
                    Divider()
                }
                if groups.count > 5 {
                    HStack {
                        Button("Previous locations") { page -= 1 }.disabled(page == 0)
                        Text("\(page + 1) / \(max(1, (groups.count + 4) / 5))").font(.caption)
                        Button("Next locations") { page += 1 }.disabled((page + 1) * 5 >= groups.count)
                    }
                }
                Text("Scope follows the folder selector above. Unknown folders, caches outside this scope and unreadable locations are not implied to be empty.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: records) { _, _ in page = 0; routeLimits = [:] }
    }

    private func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
