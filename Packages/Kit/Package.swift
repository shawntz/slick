// swift-tools-version: 6.2
// Kit: the vocabulary every feature is written in. Values, feature and view protocols, service
// protocols, and fakes for tests in KitTesting. Depends on nothing.
//
// Every feature compiles its own copy of what it imports, so optional weight lives in separate
// targets: KitStorage (SQLite and atomic JSON files), KitTemplates (the placeholder engine) and
// KitTesting (fakes and the feature harness, for test targets only).
//
// KitHosting holds the contracts between the app's own packages: Host, Root, Platform and
// SettingsUI meet there and never import each other. KitHostingTesting holds its fakes. Features
// never import either.
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

// The tests hold example features, so they compile the way feature packages do: @MainActor unless
// marked nonisolated.
let featureLikeSettings = swiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Kit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Kit", targets: ["Kit"]),
        .library(name: "KitStorage", targets: ["KitStorage"]),
        .library(name: "KitTemplates", targets: ["KitTemplates"]),
        .library(name: "KitTesting", targets: ["KitTesting"]),
        .library(name: "KitHosting", targets: ["KitHosting"]),
        .library(name: "KitHostingTesting", targets: ["KitHostingTesting"]),
    ],
    targets: [
        // No default isolation: Kit's values are built on any thread. UI-facing protocols opt in.
        .target(name: "Kit", swiftSettings: swiftSettings),
        .target(name: "KitStorage", swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "KitTemplates", dependencies: ["Kit"], swiftSettings: swiftSettings),
        .target(name: "KitTesting", dependencies: ["Kit"], swiftSettings: swiftSettings),
        .testTarget(
            name: "KitTests",
            dependencies: ["Kit", "KitStorage", "KitTemplates", "KitTesting"],
            swiftSettings: featureLikeSettings
        ),
        // No default isolation, like Kit. UI-facing protocols opt in to @MainActor.
        .target(name: "KitHosting", dependencies: ["Kit"], swiftSettings: swiftSettings),
        .target(name: "KitHostingTesting", dependencies: ["KitHosting", "KitTesting"], swiftSettings: swiftSettings),
        .testTarget(
            name: "KitHostingTests",
            dependencies: ["Kit", "KitHosting", "KitHostingTesting", "KitTesting"],
            swiftSettings: featureLikeSettings
        ),
    ]
)
