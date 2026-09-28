import AppKit
import ContextCore
import SwiftUI

struct EfficiencyOpportunityPanel: View {
    @State private var showAll = false
    let title: String
    let sourceNote: String
    let opportunities: [EfficiencyOpportunity]
    var maxVisible = 3
    var columnCount: Int? = nil
    var copyCount: Int? = nil
    var onCopyAll: (() -> Void)? = nil

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(sourceNote).font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer()
                    if let onCopyAll, (copyCount ?? opportunities.count) > 0 {
                        Button("Copy all \(copyCount ?? opportunities.count) \((copyCount ?? opportunities.count) == 1 ? "issue" : "issues")",
                               systemImage: "doc.on.doc", action: onCopyAll)
                            .font(.caption)
                    }
                }
                if opportunities.isEmpty {
                    Text("No evidence-backed review signal in the available data. Missing coverage is not a clean bill of health.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                } else {
                    LazyVGrid(columns: columnCount.map {
                        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top), count: $0)
                    } ?? [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(Array(opportunities.prefix(showAll ? opportunities.count : maxVisible))) { opportunity in
                            OpportunityRow(opportunity: opportunity)
                        }
                    }
                    if opportunities.count > maxVisible {
                        Button(showAll ? "Show fewer signals" : "Show all \(opportunities.count) signals") { showAll.toggle() }
                            .font(.caption)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OpportunityRow: View {
    let opportunity: EfficiencyOpportunity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { heading; Spacer(); confidence }
                VStack(alignment: .leading, spacing: 5) { heading; confidence }
            }
            Text(opportunity.scope).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.blue)
            Text(opportunity.action).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button(expanded ? "Hide evidence" : "Show evidence", systemImage: expanded ? "chevron.up" : "chevron.down") {
                expanded.toggle()
            }
            .font(.caption2)
            if opportunity.id.hasPrefix("otel:") {
            Button("Copy investigation brief", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(IssueBriefFormatter.telemetry([opportunity]), forType: .string)
            }.font(.caption2)
            }
            if expanded {
                Text(opportunity.evidence).font(.caption).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(opportunity.limitation).font(.caption2).foregroundStyle(DaddyTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DaddyTheme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DaddyTheme.line))
    }

    private var heading: some View {
        Text(opportunity.title).font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var confidence: some View {
        Text(opportunity.confidence.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(opportunity.confidence == .high ? DaddyTheme.mint : DaddyTheme.amber)
    }
}
