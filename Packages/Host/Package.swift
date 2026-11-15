// swift-tools-version: 6.2
// Host: the feature runtime, and Kit views on LauncherUI. Navigation, action panel, forms, toasts,
// the keyboard model and the scenario runner.
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

// The scenario runner's `record` step needs LauncherUITesting's recorder and encoders, which bring
// AVFoundation and VideoToolbox. Only a build made with SCENARIO_RECORDING=1 links them, so the
// release app does not. scenarios/media/record.sh makes that build in its own build folder.
let recording = Context.environment["SCENARIO_RECORDING"] == "1"
let recordingDependencies: [Target.Dependency] =
    recording ? [.product(name: "LauncherUITesting", package: "LauncherUI")] : []
let recordingSettings: [SwiftSetting] = recording ? [.define("SCENARIO_RECORDING")] : []

let package = Package(
    name: "Host",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Host", targets: ["Host"]),
        // Capture sheets of the real panel over fake root search, run as an app.
        .executable(name: "HostDemo", targets: ["HostDemo"]),
    ],
    dependencies: [
        .package(path: "../Kit"),
        .package(path: "../LauncherUI"),
    ],
    targets: [
        .target(
            name: "Host",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "LauncherUI", package: "LauncherUI"),
            ] + recordingDependencies,
            swiftSettings: mainActorSettings + recordingSettings
        ),
        .executableTarget(
            name: "HostDemo",
            dependencies: [
                "Host",
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "KitHostingTesting", package: "Kit"),
                .product(name: "LauncherUITesting", package: "LauncherUI"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "HostTests",
            dependencies: [
                "Host",
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "KitHostingTesting", package: "Kit"),
                .product(name: "LauncherUITesting", package: "LauncherUI"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
