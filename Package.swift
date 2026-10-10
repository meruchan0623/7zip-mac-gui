// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SevenZipMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SevenZipMac", targets: ["SevenZipMac"]), .library(name: "ArchiveCore", targets: ["ArchiveCore"])],
    targets: [
        .target(name: "ArchiveCore"),
        .executableTarget(name: "SevenZipMac", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"])
    ],
    swiftLanguageVersions: [.v5]
)
