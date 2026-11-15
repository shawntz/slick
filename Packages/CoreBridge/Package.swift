// swift-tools-version: 6.2
// CoreBridge: the only package that sees the Rust core. A C target carries the generated header and
// links libslick_ffi.a; the Swift target wraps it so nobody else imports the C module.
//
// `make core` installs the static library at Artifacts/lib/libslick_ffi.a (git ignores it) and the
// header at Sources/SlickCoreC/include/slick_core.h. The -L path is absolute, built from
// Context.packageDirectory, so linking works whichever package or Xcode project is the root.
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

let rustLibraryDirectory = Context.packageDirectory + "/Artifacts/lib"

let package = Package(
    name: "CoreBridge",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoreBridge", targets: ["CoreBridge"]),
        .executable(name: "corebridge-bench", targets: ["CoreBridgeBench"]),
    ],
    targets: [
        // The cbindgen header, its module map, and the link directives for the static library.
        .target(
            name: "SlickCoreC",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibraryDirectory]),
                .linkedLibrary("slick_ffi"),
            ]
        ),
        // No default isolation: the Rust handles are safe to use from any thread.
        .target(name: "CoreBridge", dependencies: ["SlickCoreC"], swiftSettings: swiftSettings),
        // Bench and test support: counts heap allocations through libmalloc's logger hook. Never
        // linked into the app.
        .target(name: "BenchSupport"),
        .executableTarget(
            name: "CoreBridgeBench",
            dependencies: ["CoreBridge", "BenchSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CoreBridgeTests",
            dependencies: ["CoreBridge", "SlickCoreC", "BenchSupport"],
            swiftSettings: swiftSettings
        ),
    ]
)
