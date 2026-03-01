// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Helm",
            path: "Helm",
            exclude: ["App/Info.plist", "Helm.entitlements"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .target(
            name: "Testing",
            path: "TestingSupport"
        ),
        .testTarget(
            name: "HelmTests",
            dependencies: ["Helm", "Testing"],
            path: "HelmTests"
        )
    ]
)
