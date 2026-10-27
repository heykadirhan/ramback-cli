// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ramback",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ramback", targets: ["ramback"])],
    targets: [
        .target(name: "RambackCore"),
        .executableTarget(name: "ramback", dependencies: ["RambackCore"]),
        .testTarget(name: "RambackCoreTests", dependencies: ["RambackCore"]),
    ]
)
