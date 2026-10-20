// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CRCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CRCore", targets: ["CRCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "CRCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        // Self-test runner: `swift run CRCoreSelfTest`. Used instead of XCTest/Swift Testing because
        // the Command Line Tools alone ship neither the XCTest module nor the Testing macros.
        .executableTarget(
            name: "CRCoreSelfTest",
            dependencies: ["CRCore"]
        ),
    ]
)
