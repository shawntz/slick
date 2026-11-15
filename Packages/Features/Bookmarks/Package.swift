// swift-tools-version: 6.2
// Bookmarks: search the bookmarks of Safari, the Chromium browsers and Firefox. Every browser stays
// off until the user chooses it. Reads the browsers' own files and sends nothing.
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
    name: "Bookmarks",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Bookmarks", targets: ["Bookmarks"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Bookmarks", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings,
            // Firefox keeps its bookmarks in SQLite. The parser reads them through the system library.
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(
            name: "BookmarksTests",
            dependencies: ["Bookmarks", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
