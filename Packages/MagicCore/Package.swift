// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MagicCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceCore", targets: ["DeviceCore"]),
        .library(name: "AndroidDriver", targets: ["AndroidDriver"]),
    ],
    targets: [
        .target(name: "DeviceCore"),
        .target(name: "AndroidDriver", dependencies: ["DeviceCore"]),
        .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore"]),
        .testTarget(name: "AndroidDriverTests", dependencies: ["AndroidDriver", "DeviceCore"]),
    ]
)
