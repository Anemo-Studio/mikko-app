// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mikko",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MikkoCore", targets: ["MikkoCore"]),
        .executable(name: "mikko", targets: ["mikko"]),
    ],
    targets: [
        .target(name: "MikkoCore"),
        .executableTarget(name: "mikko", dependencies: ["MikkoCore"]),
        .testTarget(name: "MikkoCoreTests", dependencies: ["MikkoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
