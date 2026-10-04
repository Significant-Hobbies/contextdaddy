import AppKit
import ContextCore
import SwiftUI

struct RedundancyReviewView: View {
    @Environment(ContextDaddyModel.self) private var model
    let compact: Bool
    @State private var showVerificationDetails = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            truthBanner
            EfficiencyOpportunityPanel(
                title: "Recommended skill reviews",
                sourceNote: "Ranked by conflict evidence and affected agents; no automatic changes.",
                opportunities: EfficiencyOpportunityAnalyzer.skills(
                    summary: model.redundancySummary, runtime: model.redundancyAgentFilter.runtime,
                    telemetry: model.telemetry),
                maxVisible: compact ? 1 : 3,
                columnCount: compact ? 1 : 3,
                copyCount: model.redundancySummary?.actionableFindings.count,
                onCopyAll: copySkillIssues)
            if model.skillIssueBaseline != nil { verificationPanel }
            if compact { compactSummary } else { summaryCards }
            controls
            LazyVStack(spacing: 8) {
                ForEach(model.visibleRedundancyFindings) { finding in
                    RedundancyFindingRow(finding: finding)
                }
                if model.visibleRedundancyFindings.isEmpty {
                    ContentUnavailableView(
                        "No matching consolidation candidates",
                        systemImage: "checkmark.seal",
                        description: Text(model.isLoading ? "Scanning bounded local skill files…" : "Change the evidence, agent, or search filter.")
                    )
                    .padding(.top, 40)
                }
            }
        }
    }

    private func copySkillIssues() {
        guard let findings = model.redundancySummary?.actionableFindings, !findings.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(IssueBriefFormatter.skills(findings), forType: .string) else { return }
        model.captureSkillIssues()
    }

    private var verificationPanel: some View {
        Panel(padding: compact ? 10 : 14) {
            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { verificationCopy; Spacer(); verifyButton }
                    VStack(alignment: .leading, spacing: 8) { verificationCopy; verifyButton }
                }
                if let result = model.skillIssueVerification {
                    Button(showVerificationDetails ? "Hide issue results" : "Show issue results",
                           systemImage: showVerificationDetails ? "chevron.up" : "chevron.down") {
                        showVerificationDetails.toggle()
                    }
                    .font(.caption)
                    if showVerificationDetails {
                        VStack(alignment: .leading, spacing: 6) {
                            verificationRows(result.cleared, status: "CLEARED", color: DaddyTheme.mint)
                            verificationRows(result.stillDetected, status: "STILL DETECTED", color: DaddyTheme.amber)
                            verificationRows(result.unverified, status: "UNVERIFIED", color: DaddyTheme.muted)
                        }
                    }
                }
            }
        }
    }

    private func verificationRows(_ findings: [SkillRedundancyFinding], status: String, color: Color) -> some View {
        ForEach(findings) { finding in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status).font(.caption2.weight(.bold)).foregroundStyle(color).frame(width: 110, alignment: .leading)
                Text(finding.members.map(\.name).joined(separator: " ↔ "))
                    .font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Text(finding.kind.rawValue).font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
            .padding(.vertical, 3)
        }
    }

    private var verificationCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Agent handoff · \(model.skillIssueBaseline?.findings.count ?? 0) copied findings")
                .font(.subheadline.weight(.semibold))
            if let result = model.skillIssueVerification {
                Text("\(result.cleared.count) cleared with the same definitions scanned · \(result.stillDetected.count) still detected · \(result.unverified.count) unverified")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                Text("Cleared verifies the detector result, not runtime quality or the safety of an edit.")
                    .font(.caption2).foregroundStyle(DaddyTheme.amber)
            } else {
                Text("Paste the brief into an agent. After changes, rescan each original finding against the same file locations.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    private var verifyButton: some View {
        Button(model.isVerifyingSkillIssues ? "Checking…" : "Verify after changes", systemImage: "arrow.clockwise") {
            Task { await model.verifySkillIssues() }
        }
        .disabled(model.isVerifyingSkillIssues)
        .font(.caption)
    }

    private var truthBanner: some View {
        Panel(padding: compact ? 10 : 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    truthBannerCopy
                    Spacer(minLength: 12)
                    Text("READ-ONLY")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(DaddyTheme.mint)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(DaddyTheme.mint.opacity(0.1), in: Capsule())
                }
                truthBannerCopy
            }
        }
    }

    private var truthBannerCopy: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "scope").foregroundStyle(DaddyTheme.mint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Evidence, not an auto-cleaner").font(.subheadline.weight(.semibold))
                Text("Exact copies use bounded SHA-256. Drift uses same-name conflicts. Purpose overlap is a local heuristic. Missing activation telemetry never means unused, and estimated savings are file bytes—not context tokens.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(compact ? 2 : nil).fixedSize(horizontal: false, vertical: !compact)
            }
        }
    }

    private var compactSummary: some View {
        let summary = model.redundancySummary
        return Panel(padding: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 70), spacing: 8), count: 6), spacing: 8) {
                compactFact("Candidates", summary?.reviewCount ?? 0, DaddyTheme.mint)
                compactFact("Exact", summary?.exactCopyCount ?? 0, DaddyTheme.blue)
                compactFact("Drift", summary?.versionDriftCount ?? 0, DaddyTheme.amber)
                compactFact("Overlap", summary?.semanticOverlapCount ?? 0, DaddyTheme.coral)
                compactFact("Cache only", summary?.managedCacheOnlyCount ?? 0, DaddyTheme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: summary?.estimatedDuplicateBytes ?? 0, countStyle: .file))
                        .font(.subheadline.bold()).monospacedDigit()
                    Text("Reviewable bytes").font(.caption2).foregroundStyle(DaddyTheme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func compactFact(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.subheadline.bold()).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(DaddyTheme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCards: some View {
        let summary = model.redundancySummary
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            summaryCard("Candidates", summary?.reviewCount ?? 0, "Review, never auto-delete", DaddyTheme.mint)
            summaryCard("Exact groups", summary?.exactCopyCount ?? 0, "Byte-identical", DaddyTheme.blue)
            summaryCard("Version drift", summary?.versionDriftCount ?? 0, "Same name, changed body", DaddyTheme.amber)
            summaryCard("Purpose overlap", summary?.semanticOverlapCount ?? 0, "Heuristic, medium confidence", DaddyTheme.coral)
            summaryCard("Managed cache", summary?.managedCacheOnlyCount ?? 0, "Separated from review", DaddyTheme.muted)
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteCountFormatter.string(fromByteCount: summary?.estimatedDuplicateBytes ?? 0, countStyle: .file))
                        .font(.title3.bold()).monospacedDigit()
                    Text("Reviewable duplicate bytes").font(.caption.weight(.semibold))
                    Text("Excludes cache-only groups").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryCard(_ title: String, _ value: Int, _ detail: String, _ color: Color) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text(value.formatted()).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                kindPicker
                agentPicker
                Spacer(minLength: 6)
                matchCount
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                HStack(spacing: 10) {
                    kindPicker
                    agentPicker
                    Spacer(minLength: 4)
                    matchCount
                }
            }
        }
    }

    private var searchField: some View {
        TextField("Search candidate, path, or evidence", text: Bindable(model).search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 210, maxWidth: 250)
    }

    private var kindPicker: some View {
        ContextChoiceMenu(
            title: "Evidence",
            selection: Bindable(model).redundancyKindFilter,
            choices: [
                ContextChoice(.review, "Review"),
                ContextChoice(.exact, "Exact copies"),
                ContextChoice(.drift, "Version drift"),
                ContextChoice(.overlap, "Purpose overlap"),
                ContextChoice(.managed, "Managed cache"),
                ContextChoice(.all, "All evidence"),
            ],
            width: 155
        )
    }

    private var agentPicker: some View {
        ContextChoiceMenu(
            title: "Agent",
            selection: Bindable(model).redundancyAgentFilter,
            choices: RedundancyAgentFilter.allCases.map { ContextChoice($0, $0.rawValue) },
            width: 155
        )
    }

    private var matchCount: some View {
        Text("\(model.visibleRedundancyFindings.count) matching")
            .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize()
    }
}

private struct RedundancyFindingRow: View {
    let finding: SkillRedundancyFinding
    @State private var expanded = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 11) {
                Button { expanded.toggle() } label: {
                    ViewThatFits(in: .horizontal) {
                        wideHeader
                        compactHeader
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 7) {
                    ForEach(finding.affectedRuntimes) { runtime in
                        Text(runtime.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
                    }
                    if finding.affectedRuntimes.isEmpty {
                        Text("No active exposure proven").font(.caption2).foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer()
                    if finding.estimatedDuplicateBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: finding.estimatedDuplicateBytes, countStyle: .file)) duplicate")
                            .font(.caption2.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    }
                }

                Text(finding.recommendation)
                    .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)

                if expanded {
                    Divider().overlay(DaddyTheme.line)
                    evidenceSection
                    membersSection
                    Label("This review never deletes or rewrites skill files.", systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(DaddyTheme.mint)
                }
            }
        }
    }

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(DaddyTheme.muted).frame(width: 14)
            findingBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text("\(finding.members.count) physical definitions").font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
            Spacer()
            confidenceBadge
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(DaddyTheme.muted)
                findingBadge
                Spacer()
                confidenceBadge
            }
            Text(title).font(.headline)
            Text("\(finding.members.count) physical definitions").font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var title: String {
        finding.members.map(\.name).uniqued().joined(separator: " ↔ ")
    }

    private var findingBadge: some View {
        Text(finding.kind.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.5)
            .foregroundStyle(kindColor)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(kindColor.opacity(0.11), in: Capsule())
    }

    private var confidenceBadge: some View {
        Text(finding.confidence.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(finding.confidence == .high ? DaddyTheme.mint : DaddyTheme.amber)
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHY IT WAS FLAGGED").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(DaddyTheme.muted)
            ForEach(finding.evidence, id: \.self) { evidence in
                Label(evidence, systemImage: "checkmark.circle").font(.caption).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEFINITIONS").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(DaddyTheme.muted)
            ForEach(finding.members) { member in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(member.name).font(.subheadline.weight(.semibold))
                        if member.id == finding.keepCandidateID {
                            Text("KEEP CANDIDATE").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(DaddyTheme.mint)
                        }
                        if member.isManagedCache {
                            Text("MANAGED CACHE").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(DaddyTheme.amber)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: member.logicalBytes, countStyle: .file))
                            .font(.caption2.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    }
                    Text(member.description).font(.caption).foregroundStyle(DaddyTheme.muted)
                    Text((member.id as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.blue).textSelection(.enabled)
                }
                .padding(10).background(DaddyTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var kindColor: Color {
        switch finding.kind {
        case .exactCopy: DaddyTheme.blue
        case .versionDrift: DaddyTheme.amber
        case .semanticOverlap: DaddyTheme.coral
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
