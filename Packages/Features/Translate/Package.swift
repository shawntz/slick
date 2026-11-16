// swift-tools-version: 6.2
// Translate: translation with Apple's Translation framework and the languages installed on the Mac.
// The feature sends nothing over the network itself and starts no download.
//
// The module is TranslateCommands rather than Translate, so it can never be confused with the
// SDK's Translation framework, which the live service imports.
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
    name: "Translate",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TranslateCommands", targets: ["TranslateCommands"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "TranslateCommands", dependencies: [.product(name: "Kit", package: "Kit")],
            swiftSettings: mainActorSettings),
        .testTarget(
            name: "TranslateCommandsTests",
            dependencies: ["TranslateCommands", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
