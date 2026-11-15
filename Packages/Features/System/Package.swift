// swift-tools-version: 6.2
// System: sleep, lock, log out, restart and shut down; empty the Trash and eject disks; dark mode
// and hidden files; the output volume; and a live process list to quit or force quit from.
//
// The module is SystemCommands rather than System, because the macOS SDK already has a Swift
// module named System.
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
    name: "System",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SystemCommands", targets: ["SystemCommands"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "SystemCommands", dependencies: [.product(name: "Kit", package: "Kit")],
            swiftSettings: mainActorSettings),
        .testTarget(
            name: "SystemCommandsTests",
            dependencies: ["SystemCommands", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
