// swift-tools-version: 6.2
// Media Controls: play, pause and skip in Apple's Music app and in Spotify from the launcher.
//
// The module is MusicControls rather than Music or MediaControls. The SDK has modules named
// MediaPlayer, MusicKit and NowPlaying, and a private framework named MediaControl, so a name near
// those could clash.
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
    name: "Music",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MusicControls", targets: ["MusicControls"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "MusicControls", dependencies: [.product(name: "Kit", package: "Kit")],
            swiftSettings: mainActorSettings),
        .testTarget(
            name: "MusicControlsTests",
            dependencies: ["MusicControls", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
