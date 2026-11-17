// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// READMEs sit beside the code they document; none is a build input.
func readmes(in directory: String) -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(directory)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }.sorted()
}

var products: [Product] = [
    .library(name: "HelmCore", targets: ["HelmCore"]),
    .library(name: "HelmFileSystem", targets: ["HelmFileSystem"]),
    .library(name: "HelmPersistence", targets: ["HelmPersistence"]),
    .library(name: "HelmOperations", targets: ["HelmOperations"]),
    .library(name: "HelmSearch", targets: ["HelmSearch"]),
    .library(name: "HelmTestKit", targets: ["HelmTestKit"]),
]
var targets: [Target] = [
    .target(name: "HelmCore", dependencies: [], exclude: readmes(in: "Sources/HelmCore")),
    .target(name: "HelmFileSystem", dependencies: ["HelmCore"], exclude: readmes(in: "Sources/HelmFileSystem")),
    .target(name: "HelmPersistence", dependencies: ["HelmCore"], exclude: readmes(in: "Sources/HelmPersistence")),
    .target(name: "HelmOperations", dependencies: ["HelmCore", "HelmFileSystem"], exclude: readmes(in: "Sources/HelmOperations")),
    .target(name: "HelmSearch", dependencies: ["HelmCore", "HelmFileSystem"], exclude: readmes(in: "Sources/HelmSearch")),
    .target(name: "HelmTestKit", dependencies: ["HelmCore", "HelmFileSystem"]),
    .testTarget(name: "HelmCoreTests", dependencies: ["HelmCore", "HelmTestKit"], exclude: readmes(in: "Tests/HelmCoreTests")),
    .testTarget(name: "HelmFileSystemTests", dependencies: ["HelmFileSystem", "HelmTestKit"]),
    .testTarget(name: "HelmPersistenceTests", dependencies: ["HelmPersistence", "HelmTestKit"]),
    .testTarget(name: "HelmOperationsTests", dependencies: ["HelmOperations", "HelmTestKit"], exclude: readmes(in: "Tests/HelmOperationsTests")),
    .testTarget(name: "HelmSearchTests", dependencies: ["HelmSearch", "HelmTestKit"], exclude: readmes(in: "Tests/HelmSearchTests")),
    .testTarget(name: "HelmTestKitTests", dependencies: ["HelmTestKit"]),
]
#if os(macOS)
// AI mode's own module. It depends on HelmCore alone, so the code that talks to a model provider can't reach a file.
targets += [
    .target(name: "HelmAgent", dependencies: ["HelmCore"], exclude: ["README.md"]),
    .testTarget(name: "HelmAgentTests", dependencies: ["HelmAgent", "HelmCore", "HelmFileSystem", "HelmTestKit"],
                resources: [.copy("Fixtures")]),
]
targets += [
    .target(name: "HelmUI", dependencies: ["HelmCore", "HelmFileSystem",
        "HelmPersistence", "HelmOperations", "HelmSearch", "HelmAgent"],
        exclude: ["README.md", "Part3-README.md", "Content/README.md",
                  "Sheets/README.md", "ViewOptions/README.md"]),
    // Fixtures/Contents holds the made-up files Read contents is tested on (scripts/rebuild/make_content_fixtures.swift).
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmCore",
        "HelmOperations", "HelmSearch", "HelmAgent", "HelmTestKit"], exclude: ["PortableRunner"],
        resources: [.copy("Fixtures")])
]
products += [.library(name: "HelmApp", targets: ["HelmApp"])]
targets += [
    .target(name: "HelmApp", dependencies: ["HelmUI", "HelmCore",
        "HelmFileSystem", "HelmPersistence", "HelmOperations", "HelmSearch", "HelmAgent"],
        exclude: ["README.md"]),
    .testTarget(name: "HelmAppTests", dependencies: ["HelmApp", "HelmCore",
        "HelmPersistence", "HelmAgent", "HelmTestKit"], exclude: ["LinuxRunner"])
]
products += [.executable(name: "HelmDev", targets: ["HelmDev"])]
targets += [.executableTarget(name: "HelmDev", dependencies: ["HelmApp"], path: "Sources/Helm")]
#endif
// #file names the module and file, not the full path, so no folder from the build machine goes into the app.
for target in targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("ConciseMagicFile")]
}
let package = Package(name: "Helm", platforms: [.macOS(.v14)], products: products,
                      targets: targets, swiftLanguageVersions: [.v5])
