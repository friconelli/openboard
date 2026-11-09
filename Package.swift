// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenBoard",
            path: "Sources/OpenBoard"
        ),
        .testTarget(
            name: "OpenBoardTests",
            dependencies: ["OpenBoard"],
            path: "Tests/OpenBoardTests"
        ),
    ]
)
