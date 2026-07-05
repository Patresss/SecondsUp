// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SecondsUp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SecondsUp", targets: ["SecondsUp"])
    ],
    targets: [
        .executableTarget(name: "SecondsUp")
    ]
)
