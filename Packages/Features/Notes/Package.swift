// swift-tools-version: 6.2
// Notes: quick notes kept as plain Markdown files that any editor can open, written, searched and
// edited from the launcher. The module is MarkdownNotes, because the SDK has private frameworks
// whose names start with Notes.
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
    name: "Notes",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MarkdownNotes", targets: ["MarkdownNotes"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "MarkdownNotes",
            dependencies: [.product(name: "Kit", package: "Kit"), .product(name: "KitStorage", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "MarkdownNotesTests",
            dependencies: [
                "MarkdownNotes",
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
