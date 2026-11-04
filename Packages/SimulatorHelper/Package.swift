// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimulatorHelper",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "tandem-simulator", targets: ["SimulatorHelper"])],
    dependencies: [.package(url: "https://github.com/facebook/homebrew-fb", exact: "1.7.7")],
    targets: [
        .executableTarget(name: "SimulatorHelper", dependencies: [
            .product(name: "FBSimulatorControl", package: "homebrew-fb"),
            .product(name: "FBSimulatorAX", package: "homebrew-fb"),
            .product(name: "FBVideoCore", package: "homebrew-fb"),
        ]),
        .testTarget(name: "SimulatorHelperTests", dependencies: ["SimulatorHelper"]),
    ]
)
