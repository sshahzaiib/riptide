// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Riptide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StreamCore", targets: ["StreamCore"])],
    targets: [
        .target(name: "StreamCore"),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
    ]
)
