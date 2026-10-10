import AppKit
import ContextCore
import SwiftUI
import SaaSMakerUI

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

    /// Daddy identity over the library's dark preset; evidence keeps its own roles.
    static let palette: SMPalette = {
        var palette = SMPalette.ink.brand(mint, foreground: .black)
        palette.background = canvas
        palette.surface = panel
        palette.card = panel
        palette.foreground = .white
        palette.mutedForeground = muted
        palette.border = line
        palette.hairline = line
        palette.success = mint
        palette.warning = amber
        palette.destructive = coral
        palette.radius = 8
        palette.displayWeight = 600
        palette.displayTracking = -0.018
        palette.textFont = palette.sansFont
        return palette
    }()

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
        SMCard(padding: padding) { content }
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
        SemanticStatusPill(text: quality.rawValue.lowercased(), color: DaddyTheme.color(for: quality))
            .accessibilityLabel(quality.rawValue.uppercased())
    }
}

struct PolicyBadge: View {
    let policy: SkillRuntimePolicy

    var body: some View {
        SemanticStatusPill(
            text: policy.mode == .automatic && !policy.explicit ? "auto · default" : policy.mode.rawValue.lowercased(),
            color: DaddyTheme.color(for: policy.mode)
        )
        .accessibilityLabel(policy.mode == .automatic && !policy.explicit ? "Auto · default" : policy.mode.rawValue)
        .help(policy.reason)
    }
}

/// SMStatusPill has no derived/blue tone. Supply the exact evidence color
/// without changing the branded palette for neighboring content.
private struct SemanticStatusPill: View {
    @Environment(\.smPalette) private var palette
    let text: String
    let color: Color

    var body: some View {
        var evidencePalette = palette
        evidencePalette.brand = color
        return SMStatusPill(text, tone: .brand)
            .environment(\.smPalette, evidencePalette)
            .fixedSize(horizontal: false, vertical: true)
    }
}
