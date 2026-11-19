// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SevenZipGUI",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "SevenZipCore",
            path: "Sources/SevenZipCore"
        ),
        .executableTarget(
            name: "SevenZipGUI",
            dependencies: ["SevenZipCore"],
            path: "Sources/SevenZipGUI"
        ),
        .testTarget(
            name: "SevenZipCoreTests",
            dependencies: ["SevenZipCore"],
            path: "Tests/SevenZipCoreTests"
        )
    ]
)
