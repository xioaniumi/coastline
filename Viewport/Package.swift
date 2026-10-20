// swift-tools-version: 6.0
import PackageDescription

// Coastline's CAM viewport: a Metal renderer for parts, stock, fixtures and millions of
// toolpath segments, wrapped for SwiftUI. Shaders compile at runtime (no Xcode `metal` tool).
let package = Package(
    name: "Viewport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Viewport", targets: ["Viewport"]),
    ],
    targets: [
        // Optimised in debug builds too (mesh building and picking over large meshes).
        .target(name: "Viewport", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
    ]
)
