// swift-tools-version: 6.2
// People: find a person in Contacts and reach them. Search Contacts lists everyone with a detail
// pane, people join root search by name, and each person's actions call, message, email or
// FaceTime them through the standard URL schemes.
//
// The module is People rather than Contacts, because the macOS SDK already has a framework named
// Contacts, which the live service imports.
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
    name: "People",
    platforms: [.macOS(.v26)],
    products: [.library(name: "People", targets: ["People"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "People", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "PeopleTests",
            dependencies: ["People", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
