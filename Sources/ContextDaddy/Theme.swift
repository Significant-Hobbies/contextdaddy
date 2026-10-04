import AppKit
import ContextCore
import SwiftUI

enum DaddyTheme {
    static let canvas = DaddyPalette.canvas
    static let panel = DaddyPalette.canvas
    static let raised = Color(red: 0.055, green: 0.075, blue: 0.066)
    static let line = mint.opacity(0.2)
    static let muted = DaddyPalette.secondaryInk
    static let mint = DaddyPalette.mint
    static let blue = DaddyPalette.blue
    static let amber = DaddyPalette.amber
    static let coral = DaddyPalette.coral

    static func color(for quality: EvidenceQuality) -> Color {
        switch quality {
        case .measured: mint
        case .derived: blue
        case .estimated, .partial: amber
        case .unavailable: muted
        }
    }

    static func color(for mode: InvocationMode) -> Color {
        switch mode {
        case .automatic: mint
        case .manualOnly: amber
        case .modelOnly: blue
        case .disabled: coral
        case .unsupported, .unverified: muted
        }
    }

    static func color(for pressure: AIContextPressure) -> Color {
        switch pressure {
        case .light: mint
        case .elevated: amber
        case .heavy: coral
        }
    }
}

struct Panel<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(DaddyTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DaddyTheme.line))
    }
}

struct ContextDaddyButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        DaddyControlStyle(prominent: prominent).makeBody(configuration: configuration)
    }
}

enum ContextDoodleTopic: Int {
    case overview = 0
    case explore = 1
    case applications = 2
    case sources = 3
    case projects = 4
    case telemetry = 5
    case cleanup = 6
    case thanks = 7
    case skills = 8
}

private enum ContextArtLoader {
    static func image(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return NSImage(contentsOf: sourceRoot.appendingPathComponent("Assets/\(name).png"))
    }
}

struct ContextDoodleArt: View {
    let topic: ContextDoodleTopic
    private static let image = ContextArtLoader.image(named: "PageDoodles")

    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geometry.size.width * 3, height: geometry.size.height * 3)
                    .offset(
                        x: -CGFloat(topic.rawValue % 3) * geometry.size.width,
                        y: -CGFloat(topic.rawValue / 3) * geometry.size.height
                    )
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func appIcon() -> NSImage? {
        guard let sheet = image else { return nil }
        let tile = NSSize(width: sheet.size.width / 3, height: sheet.size.height / 3)
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        icon.lockFocus()
        sheet.draw(
            in: NSRect(x: 0, y: 0, width: 512, height: 512),
            from: NSRect(x: tile.width * 2, y: 0, width: tile.width, height: tile.height),
            operation: .sourceOver,
            fraction: 1
        )
        icon.unlockFocus()
        return icon
    }
}

struct ContextHeroArt: View {
    private static let image = ContextArtLoader.image(named: "AIContext")

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ContextDoodleArt(topic: .skills)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct EvidenceBadge: View {
    let quality: EvidenceQuality

    var body: some View {
        Text(quality.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(DaddyTheme.color(for: quality))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(DaddyTheme.color(for: quality).opacity(0.11))
            .clipShape(Capsule())
    }
}

struct PolicyBadge: View {
    let policy: SkillRuntimePolicy

    var body: some View {
        Text(policy.mode == .automatic && !policy.explicit ? "Auto · default" : policy.mode.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DaddyTheme.color(for: policy.mode))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(DaddyTheme.color(for: policy.mode).opacity(0.1))
            .clipShape(Capsule())
            .help(policy.reason)
    }
}
