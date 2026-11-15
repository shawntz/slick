// swift-tools-version: 6.2
// Windows: move and resize the frontmost window from the launcher or a hotkey, and switch between
// open windows. Every command ships without a hotkey; presets are offered, never applied.
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
    name: "Windows",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Windows", targets: ["Windows"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Windows", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "WindowsTests",
            dependencies: ["Windows", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
