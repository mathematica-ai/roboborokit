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
        // Link this from a test bundle only. It imports XCTest.
        .library(name: "RoboboroXCTest", targets: ["RoboboroXCTest"]),
    ],
    targets: [
        .target(
            name: "RoboboroKit",
            path: "Sources/RoboboroKit",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "RoboboroXCTest",
            dependencies: ["RoboboroKit"],
            path: "Sources/RoboboroXCTest"
        ),
        .testTarget(
            name: "RoboboroKitTests",
            dependencies: ["RoboboroKit"],
            path: "Tests/RoboboroKitTests"
        ),
        .testTarget(
            name: "RoboboroXCTestTests",
            dependencies: ["RoboboroXCTest", "RoboboroKit"],
            path: "Tests/RoboboroXCTestTests"
        ),
    ]
)
