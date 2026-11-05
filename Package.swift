// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "HelmCore", targets: ["HelmCore"]),
    .library(name: "HelmFileSystem", targets: ["HelmFileSystem"]),
    .library(name: "HelmPersistence", targets: ["HelmPersistence"]),
    .library(name: "HelmOperations", targets: ["HelmOperations"]),
    .library(name: "HelmSearch", targets: ["HelmSearch"]),
    .library(name: "HelmTestKit", targets: ["HelmTestKit"]),
]
var targets: [Target] = [
    .target(name: "HelmCore", dependencies: []),
    .target(name: "HelmFileSystem", dependencies: ["HelmCore"]),
    .target(name: "HelmPersistence", dependencies: ["HelmCore"]),
    .target(name: "HelmOperations", dependencies: ["HelmCore", "HelmFileSystem"]),
    .target(name: "HelmSearch", dependencies: ["HelmCore", "HelmFileSystem"]),
    .target(name: "HelmTestKit", dependencies: ["HelmCore", "HelmFileSystem"]),
    .testTarget(name: "HelmCoreTests", dependencies: ["HelmCore", "HelmTestKit"]),
    .testTarget(name: "HelmFileSystemTests", dependencies: ["HelmFileSystem", "HelmTestKit"]),
    .testTarget(name: "HelmPersistenceTests", dependencies: ["HelmPersistence", "HelmTestKit"]),
    .testTarget(name: "HelmOperationsTests", dependencies: ["HelmOperations", "HelmTestKit"]),
    .testTarget(name: "HelmSearchTests", dependencies: ["HelmSearch", "HelmTestKit"]),
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
#endif
let package = Package(name: "Helm", platforms: [.macOS(.v14)], products: products,
                      targets: targets, swiftLanguageVersions: [.v5])
