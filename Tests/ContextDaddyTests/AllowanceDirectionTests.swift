import AppKit
import SwiftUI
import Testing
@testable import ContextDaddy

/// Direction probes only. These never check providers or change preferences.
@MainActor
struct AllowanceDirectionTests {
    @Test func renderDirections() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/allowance-directions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for direction in 0...2 {
            for width in [960, 1180, 1440] {
                let view = AllowanceDirection(direction: direction)
                    .frame(width: CGFloat(width), height: 740)
                    .background(DaddyTheme.canvas).preferredColorScheme(.dark)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 740)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(direction)-\(width).png"))
            }
        }
    }
}

private struct AllowanceDirection: View {
    let direction: Int
    private let names = ["A · Compare providers", "B · Reset agenda", "C · Provider inspector"]
    private let providers = ["Codex", "Claude", "Grok"]
    private let values = ["70%", "80%", "Not checked"]
    private let weekly = ["60%", "60%", "Not checked"]
    private let credits = ["12,345.67 credits", "$125.00", "Not checked"]
    private let grants = ["2 full resets", "1 full · 0 five-hour", "Not reported"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(names[direction]).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Provider allowance · Codex, Claude and Grok").foregroundStyle(DaddyTheme.muted)
                }
                Spacer()
                Text("Check allowances").font(.callout.weight(.semibold))
                    .padding(12).background(DaddyTheme.mint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(DaddyTheme.mint)
            }
            Text("DESIGN PREVIEW · Codex / Claude values are test fixtures. Grok has no account reading.")
                .font(.caption).foregroundStyle(DaddyTheme.amber)
            if direction == 0 { comparison }
            else if direction == 1 { agenda }
            else { inspector }
            Spacer(minLength: 0)
            HStack {
                Text("○  Check on opening Usage").font(.caption)
                Spacer()
                Text("Read-only · source and check time accompany every reading").font(.caption)
            }.foregroundStyle(DaddyTheme.muted)
        }.padding(30)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ALLOWANCE").frame(width: 175, alignment: .leading)
                ForEach(providers, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
            }.font(.title3.weight(.semibold)).padding(16)
            comparisonRow("5-hour remaining", values, emphasis: true)
            comparisonRow("Weekly remaining", weekly, emphasis: true)
            comparisonRow("Next scheduled reset", ["Today · 17:30", "Today · 20:30", "Not checked"])
            comparisonRow("Credit balance", credits)
            comparisonRow("Reset grants", grants)
            comparisonRow("First grant expiry", ["Oct 30 · 23:06", "Nov 1 · 00:00", "Not reported"])
            comparisonRow("Pay as you go", ["Not reported", "Not reported", "Not checked"])
            comparisonRow("Source & details", ["Codex app-server ›", "Claude usage ›", "Grok CLI ›"])
            Text("Codex: 1 of 2 grant details returned; an earlier expiry may exist.")
                .font(.caption).foregroundStyle(DaddyTheme.amber).padding(16)
        }.background(DaddyTheme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func comparisonRow(_ title: String, _ items: [String], emphasis: Bool = false) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(DaddyTheme.line)
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout).foregroundStyle(DaddyTheme.muted).frame(width: 175, alignment: .leading)
                ForEach(Array(items.enumerated()), id: \.offset) { _, value in
                    Text(value).font(emphasis ? .system(size: 24, weight: .semibold, design: .rounded) : .callout)
                        .foregroundStyle(emphasis && value.contains("%") ? DaddyTheme.mint : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var agenda: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Coming up").font(.title2.weight(.semibold))
                event("TODAY · 17:30", "Codex 5-hour window resets", "70% remaining in this window", color: DaddyTheme.mint)
                event("TODAY · 20:30", "Claude 5-hour window resets", "80% remaining in this window", color: DaddyTheme.mint)
                event("OCT 30 · 23:06", "First reported Codex grant expires", "2 full resets · only 1 grant detail reported", color: DaddyTheme.amber)
                event("NOT CHECKED", "Grok scheduled reset", "Check allowance to read the account schedule", color: DaddyTheme.muted)
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                Text("Balances & grants").font(.title2.weight(.semibold))
                ForEach(0..<3) { index in
                    Panel {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(providers[index]).font(.headline)
                            Text(credits[index]).font(.title3).monospacedDigit()
                            Text(grants[index]).font(.callout).foregroundStyle(DaddyTheme.mint)
                            Text(index == 2 ? "Prepaid / PAYG details: not checked" : "Weekly remaining · \(weekly[index])").font(.caption).foregroundStyle(DaddyTheme.muted)
                            Text("Source & reading details ›").font(.caption).foregroundStyle(DaddyTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(width: 300)
        }
    }

    private func event(_ date: String, _ title: String, _ detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 7) {
                Text(date).font(.caption.weight(.bold).monospaced()).foregroundStyle(color)
                Text(title).font(.title3.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(DaddyTheme.muted)
            }
            Spacer()
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
    }

    private var inspector: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3) { index in
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(providers[index]).font(.title3.weight(.semibold))
                            Text(index == 2 ? "Allowance not checked" : "\(values[index]) · 5-hour remaining").font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
                        Spacer()
                        if index == 0 { Text("›").foregroundStyle(DaddyTheme.mint) }
                    }.padding(18).background(index == 0 ? DaddyTheme.mint.opacity(0.12) : DaddyTheme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }.frame(width: 260)
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Codex").font(.system(size: 34, weight: .semibold, design: .rounded)); Spacer(); Text("PRO · FIXTURE").font(.caption).foregroundStyle(DaddyTheme.muted) }
                HStack(spacing: 40) { meter("5-hour remaining", "70%"); meter("Weekly remaining", "60%") }
                Divider().overlay(DaddyTheme.line)
                event("NEXT SCHEDULED RESET · TODAY 17:30", "5-hour window", "Weekly window resets Oct 15 · 02:43", color: DaddyTheme.mint)
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) { Text("Credits").foregroundStyle(DaddyTheme.muted); Text(credits[0]).font(.title3) }
                    VStack(alignment: .leading, spacing: 10) { Text("Reset grants").foregroundStyle(DaddyTheme.muted); Text(grants[0]).font(.title3); Text("First reported expiry · Oct 30, 23:06").font(.caption) }
                }
                Text("1 of 2 grant details returned; an earlier expiry may exist.").font(.caption).foregroundStyle(DaddyTheme.amber)
                Text("Source & reading details ›").font(.callout).foregroundStyle(DaddyTheme.muted)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(DaddyTheme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func meter(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(DaddyTheme.muted)
            Text(value).font(.system(size: 44, weight: .semibold, design: .rounded)).foregroundStyle(DaddyTheme.mint)
        }
    }
}
