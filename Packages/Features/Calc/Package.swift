// swift-tools-version: 6.2
// Calc: the calculator in root search. Arithmetic, percentages, units, currencies, dates and time
// zones come from the Rust engine through CoreBridge. Answers the user copies or pastes are kept in
// a history, and exchange rates come from the European Central Bank once a day.
//
// The module is Calc rather than Calculator, because CoreBridge has a public type named Calculator.
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
    name: "Calc",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Calc", targets: ["Calc"])],
    dependencies: [.package(path: "../../Kit"), .package(path: "../../CoreBridge")],
    targets: [
        .target(
            name: "Calc",
            dependencies: [
                .product(name: "Kit", package: "Kit"),
                .product(name: "KitStorage", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "CalcTests",
            dependencies: [
                "Calc",
                .product(name: "KitTesting", package: "Kit"),
                .product(name: "CoreBridge", package: "CoreBridge"),
            ],
            swiftSettings: mainActorSettings
        ),
    ]
)
