// swift-tools-version: 6.2
// Updates: the one package that holds Sparkle. It implements KitHosting's UpdateControl with
// Sparkle's updater for the live launcher, and only when the app's bundle carries a feed address
// and a public key. Every other run gets KitHosting's NoUpdates. No other package imports Sparkle.
//
// Sparkle is pinned to one exact version. Package.resolved pins its revision, so every build uses
// the same framework and the same signing tools. scripts/check-manifests.sh allows this one remote
// dependency here and no other anywhere.
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

// Sparkle's updater and its delegates run on the main thread, so this package is @MainActor unless
// marked nonisolated.
let mainActorSettings = swiftSettings + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Updates",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Updates", targets: ["Updates"])],
    dependencies: [
        .package(path: "../Kit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "Updates",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "UpdatesTests",
            dependencies: [
                "Updates",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
