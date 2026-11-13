// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "record2gif",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Record2GifCore", targets: ["Record2GifCore"]),
        .executable(name: "Record2Gif", targets: ["Record2Gif"])
    ],
    targets: [
        .target(
            name: "Record2GifCore",
            path: "Sources/Record2GifCore"
        ),
        .executableTarget(
            name: "Record2Gif",
            dependencies: ["Record2GifCore"],
            path: "Sources/Record2Gif"
        ),
        .testTarget(
            name: "Record2GifCoreTests",
            dependencies: ["Record2GifCore"],
            path: "Tests/Record2GifCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
