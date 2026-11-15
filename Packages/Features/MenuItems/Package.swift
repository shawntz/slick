// swift-tools-version: 6.2
// MenuItems: search the menu bar of the app that was in front when the launcher opened, and run a
// menu item from the keyboard.
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
    name: "MenuItems",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MenuItems", targets: ["MenuItems"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "MenuItems", dependencies: [.product(name: "Kit", package: "Kit")],
            swiftSettings: mainActorSettings),
        .testTarget(
            name: "MenuItemsTests",
            dependencies: ["MenuItems", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
