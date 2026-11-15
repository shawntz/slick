// swift-tools-version: 6.2
// Schedule: the user's calendar and reminders. My Schedule with meeting links and a suggestion to
// join a meeting that is about to start, Create Event, My Reminders and Create Reminder. Everything
// goes through the feature's own ScheduleStore: EventKit in the app, memory everywhere else.
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
    name: "Schedule",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Schedule", targets: ["Schedule"])],
    dependencies: [.package(path: "../../Kit")],
    targets: [
        .target(
            name: "Schedule", dependencies: [.product(name: "Kit", package: "Kit")], swiftSettings: mainActorSettings),
        .testTarget(
            name: "ScheduleTests",
            dependencies: ["Schedule", .product(name: "KitTesting", package: "Kit")],
            swiftSettings: mainActorSettings
        ),
    ]
)
