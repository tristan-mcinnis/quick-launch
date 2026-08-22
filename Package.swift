// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuickLaunch",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuickLaunch",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
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
            ],
            path: "Tests"
        ),
    ]
)
