// swift-tools-version: 6.2
// Emoji: emoji and symbols in a grid with skin tones and recents, and ":name" in root search. The
// data comes from Unicode and CLDR; Tools/generate-data.py makes it.
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
    name: "Emoji",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Emoji", targets: ["Emoji"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Emoji", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "EmojiTests",
            dependencies: ["Emoji", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
