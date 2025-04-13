// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XcodeBuildServer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .executable(
            name: "XcodeBuildServer",
            targets: ["XcodeBuildServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-build.git", branch: "main"),
        .package(url: "https://github.com/mcfans/sourcekit-lsp.git", revision: "8841553a16a3d431a05a17aa1f246ca1214d757b"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
        .package(url: "https://github.com/groue/Semaphore.git", branch: "main")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "XcodeBuildServer",
            dependencies: [
                .product(name: "SwiftBuild", package: "swift-build"),
                .product(name: "SWBBuildService", package: "swift-build"),
                .product(name: "BSPBindings", package: "sourcekit-lsp"),
                .product(name: "Semaphore", package: "Semaphore")
            ]
        ),
        .testTarget(
            name: "XcodeBuildServerTests",
            dependencies: ["XcodeBuildServer"]
        ),
    ]
)
