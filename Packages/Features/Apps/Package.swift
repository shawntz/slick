// swift-tools-version: 6.2
// Apps: installed applications and System Settings panes in root search, running-app actions, and
// the Quit All and Running Applications commands. The reference feature: read it next to
// docs/FEATURES.md.
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
    name: "Apps",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Apps", targets: ["Apps"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(name: "Apps", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "AppsTests",
            dependencies: ["Apps", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
