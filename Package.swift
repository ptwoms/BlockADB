// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "BlockADB",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "BlockADB", targets: ["BlockADB"]),
        .library(name: "BlockADBCore", targets: ["BlockADBCore"])
    ],
    targets: [
        .executableTarget(
            name: "BlockADB",
            dependencies: ["BlockADBCore"],
            path: "Sources/BlockADB"
        ),
        .target(
            name: "BlockADBCore",
            dependencies: [],
            path: "Sources/BlockADBCore",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "BlockADBTests",
            dependencies: ["BlockADBCore"],
            path: "Tests/BlockADBTests"
        )
    ]
)
