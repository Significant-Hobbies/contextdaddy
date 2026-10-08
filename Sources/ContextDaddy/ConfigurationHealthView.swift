import AppKit
import ContextCore
import SwiftUI

struct ConfigurationHealthView: View {
    @Environment(ContextDaddyModel.self) private var model
    let report: ConfigurationHealthReport
    var runtime: AgentRuntime = .codex

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.scannedFiles.isEmpty ? "Setup has not been verified" : report.issues.isEmpty ? "No supported setup problems found" : "\(report.issues.count) setup \(report.issues.count == 1 ? "problem" : "problems") to resolve")
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("\(runtime.rawValue) configuration · \(report.errorCount) errors · \(report.warningCount) warnings · \(report.scannedFiles.count) configuration \(report.scannedFiles.count == 1 ? "file" : "files") checked")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                    HStack {
                        statusBadge
                        if !report.issues.isEmpty {
                            Button("Copy all \(report.issues.count) \(report.issues.count == 1 ? "issue" : "issues")", systemImage: "doc.on.doc", action: copyAll)
                                .font(.caption).fixedSize()
                        }
                    }
                }

                Text("Checks local configuration structure, declared MCP launchers, Claude @imports, skill descriptions and links, and memory file sizes. Credentials, remote connectivity, managed settings and launch-time overrides are not tested.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                if model.configurationIssueBaseline != nil {
                    HStack(spacing: 12) {
                        if let result = model.configurationIssueVerification {
                            Text("\(result.cleared.filter { $0.runtime == runtime }.count) detector-cleared · \(result.stillDetected.filter { $0.runtime == runtime }.count) still detected · \(result.unverified.filter { $0.runtime == runtime }.count) unverified")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        } else {
                            Text("Agent handoff copied. Rescan after changes; missing config files remain unverified.")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
                        Spacer()
                        Button(model.isVerifyingConfigurationIssues ? "Checking…" : "Verify after changes",
                               systemImage: "arrow.clockwise") {
                            Task { await model.verifyConfigurationIssues() }
                        }
                        .disabled(model.isVerifyingConfigurationIssues)
                        .font(.caption)
                    }
                    if let result = model.configurationIssueVerification {
                        ForEach(result.cleared.filter { $0.runtime == runtime }) { issue in issueStatus(issue, "CLEARED", DaddyTheme.mint) }
                        ForEach(result.stillDetected.filter { $0.runtime == runtime }) { issue in issueStatus(issue, "STILL DETECTED", DaddyTheme.amber) }
                        ForEach(result.unverified.filter { $0.runtime == runtime }) { issue in issueStatus(issue, "UNVERIFIED", DaddyTheme.muted) }
                    }
                }

                if !report.issues.isEmpty {
                    ForEach(report.issues) { issue in
                        Divider().overlay(DaddyTheme.line)
                        issueRow(issue)
                    }
                } else if report.scannedFiles.isEmpty {
                    Label("No readable supported agent configuration was found.", systemImage: "questionmark.folder")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                } else if report.issues.isEmpty {
                    Label("No structural configuration problems detected.", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                }

                DisclosureGroup("What was checked") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(report.files) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            Text((file.path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).textSelection(.enabled)
                            Text(file.status.rawValue + " · " + file.detail)
                                .foregroundStyle(file.status == .unverified ? DaddyTheme.amber : DaddyTheme.muted)
                        }
                    }
                    Label("Checks user files, the selected folder and discovered project folders. Inherited, custom-home and managed settings may add other sources. Missing optional files are not errors.", systemImage: "info.circle")
                    Label("Read-only check: credential, header, environment, and MCP argument values are ignored.", systemImage: "lock.shield")
                }
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
                }.font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(IssueBriefFormatter.configuration(report.issues), forType: .string) else { return }
        model.captureConfigurationIssues(report.issues)
    }

    private func issueStatus(_ issue: ConfigurationHealthIssue, _ status: String, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Text(status).font(.caption2.weight(.bold)).foregroundStyle(color).frame(width: 110, alignment: .leading)
            Text(issue.title).font(.caption)
            Spacer()
            Text("\(issue.runtime.rawValue) · line \(issue.line)")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var statusBadge: some View {
        let color = report.errorCount > 0 ? DaddyTheme.coral : report.scannedFiles.isEmpty || report.files.contains { $0.status == .unverified } ? DaddyTheme.amber : report.warningCount > 0 ? DaddyTheme.amber : DaddyTheme.mint
        let label = !report.issues.isEmpty ? "\(report.issues.count) FILE ISSUES" : report.scannedFiles.isEmpty ? "UNVERIFIED" : report.files.contains { $0.status == .unverified } ? "PARTIAL" : "CHECKED"
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
    }

    private func issueRow(_ issue: ConfigurationHealthIssue) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 11) {
                issueIcon(issue)
                issueCopy(issue)
                Spacer(minLength: 12)
                actions(issue)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    issueIcon(issue)
                    issueCopy(issue)
                }
                actions(issue)
            }
        }
    }

    private func issueIcon(_ issue: ConfigurationHealthIssue) -> some View {
        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(issue.severity == .error ? DaddyTheme.coral : DaddyTheme.amber)
            .frame(width: 18)
    }

    private func issueCopy(_ issue: ConfigurationHealthIssue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.title).font(.subheadline.weight(.semibold))
            Text("Impact: " + issue.detail).font(.caption).foregroundStyle(DaddyTheme.muted)
            Text("\((issue.path as NSString).abbreviatingWithTildeInPath):\(issue.line)")
                .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.blue).textSelection(.enabled)
            Text("Next step: " + issue.remediation).font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actions(_ issue: ConfigurationHealthIssue) -> some View {
        HStack(spacing: 8) {
            Button("Copy fix", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(IssueBriefFormatter.configuration([issue]), forType: .string) {
                    model.captureConfigurationIssues([issue])
                }
            }
            Button("Reveal", systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: issue.path)])
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}
