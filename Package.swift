// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoboboroKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "RoboboroKit", targets: ["RoboboroKit"]),
    ],
    targets: [
        .target(
            name: "RoboboroKit",
            path: "Sources/RoboboroKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "RoboboroKitTests",
            dependencies: ["RoboboroKit"],
            path: "Tests/RoboboroKitTests"
        ),
    ]
)
