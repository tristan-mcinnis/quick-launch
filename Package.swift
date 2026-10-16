// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickLaunch",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.5.0"),
        // The shared House chat core: schema, archives, retrieval policy,
        // slash commands. A sibling repo, consumed by Quick Launch and RTI.
        .package(path: "../house-chat-core"),
    ],
    targets: [
        .executableTarget(
            name: "QuickLaunch",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "HouseChatCore", package: "house-chat-core"),
                .product(name: "HouseChatDocuments", package: "house-chat-core"),
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "./Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "QuickLaunchTests",
            dependencies: [
                "QuickLaunch",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "HouseChatCore", package: "house-chat-core"),
                .product(name: "HouseChatDocuments", package: "house-chat-core"),
            ],
            path: "Tests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
