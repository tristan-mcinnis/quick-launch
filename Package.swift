// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickLaunch",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.5.0"),
        // The shared House chat core: schema, archives, retrieval policy,
        // slash commands. Quick Launch consumes it; RTI consumes it separately.
        .package(path: "Packages/HouseChatCore"),
    ],
    targets: [
        .executableTarget(
            name: "QuickLaunch",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "HouseChatCore", package: "HouseChatCore"),
                .product(name: "HouseChatDocuments", package: "HouseChatCore"),
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
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
                .product(name: "HouseChatCore", package: "HouseChatCore"),
                .product(name: "HouseChatDocuments", package: "HouseChatCore"),
            ],
            path: "Tests",
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
