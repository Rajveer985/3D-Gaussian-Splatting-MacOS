// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "GaussianSplatViewer",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "GaussianSplatViewer", targets: ["GaussianSplatViewer"])
    ],
    targets: [
        .executableTarget(
            name: "GaussianSplatViewer",
            path: "Sources",
            resources: [
                .process("Shaders")
            ]
        )
    ]
)
