// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenBoard",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "OpenBoard",
            dependencies: ["SwiftTerm"],
            path: "Sources/OpenBoard"
        ),
        .testTarget(
            name: "OpenBoardTests",
            dependencies: ["OpenBoard"],
            path: "Tests/OpenBoardTests"
        ),
    ]
)
