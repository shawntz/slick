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
            ],
            swiftSettings: mainActorSettings
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
