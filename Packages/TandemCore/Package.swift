// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TandemCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceCore", targets: ["DeviceCore"]),
        .library(name: "AndroidDriver", targets: ["AndroidDriver"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "ControlProtocol", targets: ["ControlProtocol"]),
    ],
    targets: [
        .target(name: "DeviceCore"),
        .target(name: "AndroidDriver", dependencies: ["DeviceCore"]),
        .target(name: "MediaKit", dependencies: ["DeviceCore"]),
        .target(name: "ControlProtocol"),
        .testTarget(name: "ControlProtocolTests", dependencies: ["ControlProtocol"]),
        .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "DeviceCore"]),
        .testTarget(name: "AndroidDriverTests", dependencies: ["AndroidDriver", "DeviceCore", "MediaKit"], resources: [.copy("Fixtures")]),
    ]
)
