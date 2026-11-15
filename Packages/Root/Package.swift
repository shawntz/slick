// swift-tools-version: 6.2
// Root: root search. Engine queries, live providers, suggestions, favorites, aliases, fallbacks
// and learning.
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
    name: "Root",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Root", targets: ["Root"]),
        .executable(name: "root-bench", targets: ["RootBench"]),
    ],
    dependencies: [
        .package(path: "../Kit"),
        .package(path: "../CoreBridge"),
    ],
    targets: [
        .target(
            name: "Root",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                // Root meets Host, Platform and SettingsUI only through these contracts.
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings
        ),
        // Bench support: counts the calling thread's heap allocations and reads its CPU time. Never
        // linked into the app.
        .target(name: "RootBenchSupport"),
        // The latency budgets of the synchronous path. Run it with
        // `scripts/swiftpm.sh Packages/Root run -c release root-bench`.
        .executableTarget(
            name: "RootBench",
            dependencies: [
                "Root",
                "RootBenchSupport",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "KitHostingTesting", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "RootTests",
            dependencies: [
                "Root",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "KitHostingTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
