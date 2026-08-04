// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeepoCore",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "KeepoCore", targets: ["KeepoCore"])
    ],
    targets: [
        .target(name: "KeepoCore"),
        .testTarget(name: "KeepoCoreTests", dependencies: ["KeepoCore"])
    ]
)
