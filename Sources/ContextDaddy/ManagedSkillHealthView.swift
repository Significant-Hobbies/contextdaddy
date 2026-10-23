import ContextCore
import SwiftUI

struct ManagedSkillHealthView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        title.fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        checkButton
                    }
                    VStack(alignment: .leading, spacing: 8) { title; checkButton }
                }
                if let report = model.managedSkillHealth {
                    Label(report.healthy ? "Registered setup matches" : "Managed setup needs review",
                          systemImage: report.healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.healthy ? DaddyTheme.mint : DaddyTheme.amber)
                    Text("\(report.summary.entryCount) entries · \(report.summary.problemCount) installation problems · \(report.summary.unmanagedCount) unmanaged")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Hourly maintenance: \(report.maintenance.status). Scope: \(report.maintenance.scope).")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                    ForEach(Array(report.findings.prefix(8)), id: \.self) { finding in
                        Text(finding).font(.caption).foregroundStyle(DaddyTheme.amber)
                    }
                    if report.findings.count > 8 { Text("\(report.findings.count - 8) additional findings in agent-config status.").font(.caption) }
                    DisclosureGroup("What this verifies") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Pinned revisions, materialized content against its sync snapshot, patch and policy recipes, registered links, and maintenance registration and last exit status.")
                            Text("Scope: \(report.scope). Checked: \(report.generatedAt).")
                            if report.repositoryDirty { Text("The manager repository has uncommitted changes; they were preserved.") }
                            Text("This check is read-only. Plugin activation, credentials and successful skill use are separate evidence. Desktop targets require manual sync after changes.")
                        }.font(.caption).foregroundStyle(DaddyTheme.muted)
                    }.font(.caption)
                } else {
                    Text(model.managedSkillHealthError ?? "Managed setup has not been checked.")
                        .font(.caption).foregroundStyle(DaddyTheme.amber)
                }
                Text("Runs the installed agent-config status command. It does not sync or repair skills.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                Text("The broader scan below can still find problems outside the manager’s registered targets. A partial discovery scan is not an all-clear.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Managed setup").font(.headline)
            Text("agent-config · registered installations across agents")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var checkButton: some View {
        Button(model.isCheckingManagedSkills ? "Checking…" : "Check managed setup") {
            Task { await model.checkManagedSkills() }
        }.disabled(model.isCheckingManagedSkills)
    }
}
