// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pollymetric",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pollymetric", targets: ["Pollymetric"]),
        // Harness discovery, auth status, sign-in and launch commands for local agent
        // CLIs, driven by descriptors. Usable on its own.
        .library(name: "HarnessKit", targets: ["HarnessKit"]),
    ],
    targets: [
        .target(name: "HarnessKit", path: "Sources/HarnessKit"),
        .executableTarget(
            name: "Pollymetric",
            dependencies: ["HarnessKit"],
            path: "Sources/Pollymetric"
        ),
        .testTarget(
            name: "PollymetricTests",
            dependencies: ["Pollymetric", "HarnessKit"],
            path: "Tests/PollymetricTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
