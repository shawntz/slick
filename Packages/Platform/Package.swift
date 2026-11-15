// swift-tools-version: 6.2
// Platform: live implementations of Kit's service protocols and of the KitHosting services Platform
// owns: settings, storage, secrets, clock, processes, HTTP, file watching, file dialogs,
// permissions, workspace, hotkeys, pasteboard, selection, text expansion, icons, system context
// and the login item. PlatformServices builds them for a run environment.
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
    name: "Platform",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Platform", targets: ["Platform"])],
    dependencies: [
        .package(path: "../Kit")
    ],
    targets: [
        .target(
            name: "Platform",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "PlatformTests",
            dependencies: [
                "Platform",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
