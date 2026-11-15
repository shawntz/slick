// swift-tools-version: 6.2
// Clipboard: clipboard history. Records what other apps copy into SQLite in the feature's own
// folder, lists it with search, a type filter and a preview, and pastes it back.
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
    name: "Clipboard",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Clipboard", targets: ["Clipboard"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Clipboard",
            dependencies: [.product(name: "Kit", package: "Kit"), .product(name: "KitStorage", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "ClipboardTests",
            dependencies: [
                "Clipboard", .product(name: "KitStorage", package: "Kit"), .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
