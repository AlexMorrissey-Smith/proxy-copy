// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "proxy-copy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "proxy-copy", targets: ["proxy-copy"])],
    targets: [
        .executableTarget(name: "proxy-copy", path: "Sources"),
        .testTarget(name: "ProxyCopyTests", dependencies: ["proxy-copy"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
