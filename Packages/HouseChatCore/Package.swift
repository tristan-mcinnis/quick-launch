// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HouseChatCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HouseChatCore", targets: ["HouseChatCore"]),
        .library(name: "HouseChatDocuments", targets: ["HouseChatDocuments"]),
    ],
    targets: [
        .target(name: "HouseChatCore"),
        .target(
            name: "HouseChatDocuments",
            dependencies: ["HouseChatCore"],
            path: "Sources/HouseChatDocuments",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "HouseChatDocumentsTests",
            dependencies: ["HouseChatDocuments"],
            path: "Tests/HouseChatDocumentsTests"
        ),
        .testTarget(
            name: "HouseChatCoreTests",
            dependencies: ["HouseChatCore"]
        ),
    ]
)
