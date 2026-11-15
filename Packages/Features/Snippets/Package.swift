// swift-tools-version: 6.2
// Snippets: saved text with dynamic placeholders, pasted from a list or root search, or expanded by
// typing its keyword in any app.
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
    name: "Snippets",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Snippets", targets: ["Snippets"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Snippets",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "SnippetsTests",
            dependencies: [
                "Snippets",
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
