// swift-tools-version: 6.2
// LauncherUI: pure AppKit rendering of the launcher. It knows nothing about features, the engine
// or Kit, and depends on nothing.
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
    name: "LauncherUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LauncherUI", targets: ["LauncherUI"]),
        .library(name: "LauncherUITesting", targets: ["LauncherUITesting"]),
        // Captures, benchmarks and synthetic typing, run as an app by scripts/ui-demo.sh.
        .executable(name: "LauncherUIDemo", targets: ["LauncherUIDemo"]),
    ],
    targets: [
        .target(name: "LauncherUI", swiftSettings: mainActorSettings),
        .target(
            name: "LauncherUITesting",
            dependencies: ["LauncherUI"],
            swiftSettings: mainActorSettings,
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "LauncherUIDemo",
            dependencies: ["LauncherUI", "LauncherUITesting"],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "LauncherUITests",
            dependencies: ["LauncherUI", "LauncherUITesting"],
            swiftSettings: mainActorSettings
        ),
    ]
)
