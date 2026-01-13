// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mac2Droid",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Mac2Droid",
            targets: ["Mac2Droid"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Mac2Droid",
            path: "Mac2Droid",
            exclude: ["Info.plist", "Mac2Droid.entitlements"]
        )
    ]
)
