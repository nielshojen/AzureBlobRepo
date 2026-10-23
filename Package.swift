// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AzureBlobRepo",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AzureBlobRepo",
            type: .dynamic,
            targets: ["AzureBlobRepo"]
        )
    ],
    targets: [
        .target(
            name: "AzureBlobRepo",
            path: "Sources/AzureBlobRepo"
        ),
        .testTarget(
            name: "AzureBlobRepoTests",
            dependencies: ["AzureBlobRepo"],
            path: "Tests/AzureBlobRepoTests"
        )
    ]
)
