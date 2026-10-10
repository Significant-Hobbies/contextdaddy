// swift-tools-version: 6.0
import PackageDescription
import Foundation

let sparkleTestFrameworks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64").path

let package = Package(
    name: "ContextDaddy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ContextCore", targets: ["ContextCore"]),
        .executable(name: "ContextDaddy", targets: ["ContextDaddy"]),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"), .package(url: "https://github.com/sass-maker/ui-library", from: "0.1.14")],
    targets: [
        .target(name: "ContextCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ContextDaddy", dependencies: [.product(name: "SaaSMakerUI", package: "ui-library"), "ContextCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ContextCoreTests", dependencies: ["ContextCore"]),
        .testTarget(name: "ContextDaddyTests", dependencies: ["ContextDaddy"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sparkleTestFrameworks])]),
    ]
)
