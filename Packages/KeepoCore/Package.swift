// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeepoCore",
    // macOS floor is for `swift build`/`swift test` on the host Mac only —
    // the app itself only ever builds for iOS. Required by supabase-swift.
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "KeepoCore", targets: ["KeepoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.5.1")
    ],
    targets: [
        .target(
            name: "KeepoCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ]
        ),
        .testTarget(name: "KeepoCoreTests", dependencies: ["KeepoCore"])
    ]
)
