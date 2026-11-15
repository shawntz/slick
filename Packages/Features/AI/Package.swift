// swift-tools-version: 6.2
// AI: ask a model from the launcher with a provider the user chooses: Apple's on-device model, the
// Anthropic API, or any server that speaks the OpenAI chat completions format. Ask AI, AI Chat,
// commands on selected text, and the user's own prompts.
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
    name: "AI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AI", targets: ["AI"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "AI",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "AITests",
            dependencies: [
                "AI",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "KitTemplates", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
