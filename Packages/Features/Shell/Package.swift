// swift-tools-version: 6.2
// Shell: a command typed after ">" in root search runs in the user's login shell, and its output
// streams into a page. Past commands are kept in a history.
//
// The module is ShellCommands rather than Shell, so it cannot clash with a module or a type of that
// name in the SDK or in another package.
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
    name: "Shell",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ShellCommands", targets: ["ShellCommands"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "ShellCommands",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "ShellCommandsTests",
            dependencies: ["ShellCommands", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
