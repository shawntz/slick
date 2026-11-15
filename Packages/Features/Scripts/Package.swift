// swift-tools-version: 6.2
// Scripts: script commands. A script dropped in a script folder becomes a command, in the comment
// format of the public script command collections, with five output modes including a list that
// reads Script Filter JSON.
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
    name: "Scripts",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Scripts", targets: ["Scripts"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Scripts", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "ScriptsTests",
            dependencies: ["Scripts", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
