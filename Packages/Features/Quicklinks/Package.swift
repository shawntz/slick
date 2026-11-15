// swift-tools-version: 6.2
// Quicklinks: open sites, searches and deep links by name, about thirty built-in web searches, a
// strict web address detector in root search, and a web search when nothing else matches.
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
    name: "Quicklinks",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Quicklinks", targets: ["Quicklinks"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Quicklinks",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "QuicklinksTests",
            dependencies: [
                "Quicklinks",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
