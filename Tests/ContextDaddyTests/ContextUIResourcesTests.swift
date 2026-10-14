import Foundation
import SaaSMakerUI
import Testing
@testable import ContextDaddy

struct ContextUIResourcesTests {
    @Test func missingBundleUsesFallback() {
        #expect(!ContextUIResources.registerFonts(in: nil))
    }

    @Test func incompleteAndCorruptFontsFailQualificationWithoutTrapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-fonts-\(UUID().uuidString).bundle")
        let fonts = root.appendingPathComponent("Contents/Resources/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: root))
        #expect(!ContextUIResources.registerFonts(in: bundle))
        for name in SMFonts.files {
            try Data("invalid font".utf8).write(to: fonts.appendingPathComponent(name + ".ttf"))
        }
        #expect(!ContextUIResources.registerFonts(in: bundle))
    }
}
