// swift-tools-version: 6.2
// FileSearch: find files by name from root search and the Search Files page, over the launcher's
// own index of file names in the Rust core. It indexes only places that raise no system prompt
// until the user asks for more.
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
    name: "FileSearch",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FileSearch", targets: ["FileSearch"])],
    dependencies: [.package(path: "../../Kit"), .package(path: "../../CoreBridge")],
    targets: [
        .target(
            name: "FileSearch",
            dependencies: [
                .product(name: "Kit", package: "Kit"), .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings),
        .testTarget(
            name: "FileSearchTests",
            dependencies: [
                "FileSearch", .product(name: "KitTesting", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
