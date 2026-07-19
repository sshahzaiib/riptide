// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Riptide",
    platforms: [.macOS(.v26)],
    products: [.library(name: "StreamCore", targets: ["StreamCore"])],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.41.0"),
    ],
    targets: [
        .target(name: "StreamCore"),
        .target(name: "DownloadKit", exclude: ["VENDORED.md"]),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
        .executableTarget(
            name: "RiptideApp",
            dependencies: [
                "StreamCore",
                "DownloadKit",
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            // mpv's C callback interop is not strict-concurrency-clean; the
            // downgrade is scoped to the app target only.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
