// swift-tools-version: 6.2
// SettingsUI: the settings window, onboarding and the hotkey recorder. It meets Host, Root and Platform
// only through the protocols in KitHosting, which App connects.
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
    name: "SettingsUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SettingsUI", targets: ["SettingsUI"])],
    dependencies: [
        .package(path: "../Kit"),
        .package(path: "../LauncherUI"),
    ],
    targets: [
        .target(
            name: "SettingsUI",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "LauncherUI", package: "LauncherUI"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "SettingsUITests",
            dependencies: [
                "SettingsUI",
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "KitHostingTesting", package: "Kit"),
                .product(name: "LauncherUITesting", package: "LauncherUI"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
