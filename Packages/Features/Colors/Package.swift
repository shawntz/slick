// swift-tools-version: 6.2
// Colors: pick a color on screen, keep a history of colors, and convert colors typed in root search
// between hex, RGB, HSL, HSB, HWB, OKLCH, SwiftUI, AppKit and a CSS variable, with WCAG contrast.
//
// The module is ColorTools rather than Colors, so it cannot clash with a type or module of that
// name in the SDK or in another package.
import PackageDescription

// Shared settings. Keep this block identical in every Package.swift: scripts/check-manifests.sh
// fails the lint when one drifts.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

// UI, host and feature code is @MainActor unless marked nonisolated or @concurrent.
let mainActorSettings = swiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Colors",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ColorTools", targets: ["ColorTools"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "ColorTools",
            dependencies: [.product(name: "Kit", package: "Kit"), .product(name: "KitStorage", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "ColorToolsTests",
            dependencies: ["ColorTools", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
