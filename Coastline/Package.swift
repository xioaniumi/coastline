// swift-tools-version: 6.0
import PackageDescription

// The Coastline macOS app. Built with SwiftPM (no Xcode); scripts/make-app.sh wraps the
// executable into Coastline.app. Build with scripts/build-app.sh (sets the SDK).
let package = Package(
    name: "Coastline",
    platforms: [.macOS("26.0")],  // Liquid Glass APIs without fallbacks (personal app, macOS 27)
    dependencies: [
        .package(path: "../CoastlineCore"),
        .package(path: "../Viewport"),
    ],
    targets: [
        .executableTarget(
            name: "Coastline",
            dependencies: ["CoastlineCore", "Viewport"]
        ),
    ]
)
