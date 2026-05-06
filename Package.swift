// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "GaussianSplatViewer",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "GaussianSplatViewer", targets: ["GaussianSplatViewer"])
    ],
    dependencies: [
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "GaussianSplatViewer",
            path: "Sources",
            resources: [
                .process("Shaders")
            ]
        ),
        .testTarget(
            name: "AnimationSystem",
            dependencies: [
                .product(name: "SwiftCheck", package: "SwiftCheck")
            ],
            path: "Tests/AnimationSystem"
        )
    ]
)
