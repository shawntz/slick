// swift-tools-version: 6.2
// App: the composition root. SlickApp holds the app code, so the SwiftPM executable and the
// optional Xcode app target share it; the Slick executable is a one-line main. scripts/bundle.sh
// names the executable inside the app bundle after BRAND_NAME in support/brand.env.
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
    name: "App",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Slick", targets: ["Slick"]),
        .library(name: "SlickApp", targets: ["SlickApp"]),
    ],
    dependencies: [
        .package(path: "../Kit"),
        .package(path: "../LauncherUI"),
        .package(path: "../Platform"),
        .package(path: "../Host"),
        .package(path: "../Root"),
        .package(path: "../SettingsUI"),
        .package(path: "../CoreBridge"),
        // Features, one line each, in the order of Sources/SlickApp/Features.swift.
        .package(path: "../Features/Apps"),
        .package(path: "../Features/Clipboard"),
        .package(path: "../Features/Snippets"),
        .package(path: "../Features/Quicklinks"),
        .package(path: "../Features/Emoji"),
        .package(path: "../Features/Windows"),
        .package(path: "../Features/System"),
        .package(path: "../Features/Scripts"),
        .package(path: "../Features/Calc"),
        .package(path: "../Features/FileSearch"),
        .package(path: "../Features/Define"),
        .package(path: "../Features/Schedule"),
        .package(path: "../Features/People"),
        .package(path: "../Features/Bookmarks"),
        .package(path: "../Features/AI"),
        .package(path: "../Features/MenuItems"),
    ],
    targets: [
        .target(
            name: "SlickApp",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "LauncherUI", package: "LauncherUI"),
                .product(name: "Platform", package: "Platform"),
                .product(name: "Host", package: "Host"),
                .product(name: "Root", package: "Root"),
                .product(name: "SettingsUI", package: "SettingsUI"),
                .product(name: "CoreBridge", package: "CoreBridge"),
                .product(name: "Apps", package: "Apps"),
                .product(name: "Clipboard", package: "Clipboard"),
                .product(name: "Snippets", package: "Snippets"),
                .product(name: "Quicklinks", package: "Quicklinks"),
                .product(name: "Emoji", package: "Emoji"),
                .product(name: "Windows", package: "Windows"),
                .product(name: "SystemCommands", package: "System"),
                .product(name: "Scripts", package: "Scripts"),
                .product(name: "Calc", package: "Calc"),
                .product(name: "FileSearch", package: "FileSearch"),
                .product(name: "Define", package: "Define"),
                .product(name: "Schedule", package: "Schedule"),
                .product(name: "People", package: "People"),
                .product(name: "Bookmarks", package: "Bookmarks"),
                .product(name: "AI", package: "AI"),
                .product(name: "MenuItems", package: "MenuItems"),
            ],
            swiftSettings: mainActorSettings
        ),
        .executableTarget(name: "Slick", dependencies: ["SlickApp"], swiftSettings: mainActorSettings),
        .testTarget(
            name: "SlickAppTests",
            dependencies: [
                "SlickApp",
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitHosting", package: "Kit"),
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "Host", package: "Host"),
                .product(name: "Root", package: "Root"),
                .product(name: "Platform", package: "Platform"),
                .product(name: "SettingsUI", package: "SettingsUI"),
                .product(name: "LauncherUI", package: "LauncherUI"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
