// swift-tools-version: 6.0
import PackageDescription

// Coastline's logic: machine profile, inventory, feeds, planning, safety, export and the engine
// client. No UI, so it builds and tests with a plain `swift build` (Command Line Tools only).
let package = Package(
    name: "CoastlineCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoastlineCore", targets: ["CoastlineCore"]),
    ],
    dependencies: [
        // CRCore: .crproj model/writer, G-code classifier, guided navigator.
        .package(path: "../CRCore"),
        // Reading Fusion .tools libraries (zip). Same package CRCore already uses.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // Optimised even in debug builds: the material-removal simulation, the planner timing
        // and the fixture checks run per move over tens of thousands of moves, ~20× slower
        // unoptimised. (The app itself stays a debug build: a release build of its async code
        // trips a Swift runtime bug, "freed pointer was not the last allocation".)
        .target(name: "CoastlineCore", dependencies: [
            "CRCore",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // Self-test runner (XCTest and the Testing macros need Xcode; see scripts/selftest.sh).
        .executableTarget(name: "CoastlineSelfTest", dependencies: ["CoastlineCore", "CRCore"]),
    ]
)
