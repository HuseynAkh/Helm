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
targets += [
    .target(name: "HelmUI", dependencies: ["HelmCore", "HelmFileSystem",
        "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md", "Part3-README.md", "Content/README.md",
                  "Sheets/README.md", "ViewOptions/README.md"]),
    .testTarget(name: "HelmUITests", dependencies: ["HelmUI", "HelmCore",
        "HelmOperations", "HelmSearch", "HelmTestKit"], exclude: ["PortableRunner"])
]
products += [.library(name: "HelmApp", targets: ["HelmApp"])]
targets += [
    .target(name: "HelmApp", dependencies: ["HelmUI", "HelmCore",
        "HelmFileSystem", "HelmPersistence", "HelmOperations", "HelmSearch"],
        exclude: ["README.md"]),
    .testTarget(name: "HelmAppTests", dependencies: ["HelmApp", "HelmCore",
        "HelmPersistence", "HelmTestKit"], exclude: ["LinuxRunner"])
]
products += [.executable(name: "HelmDev", targets: ["HelmDev"])]
targets += [.executableTarget(name: "HelmDev", dependencies: ["HelmApp"], path: "Sources/Helm")]
#endif
let package = Package(name: "Helm", platforms: [.macOS(.v14)], products: products,
                      targets: targets, swiftLanguageVersions: [.v5])
