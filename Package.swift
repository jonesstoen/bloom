// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImmichKit",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "ImmichKit", targets: ["ImmichAPI", "ImmichKit", "ImmichUI"]),
    ],
    targets: [
        .target(name: "ImmichAPI"),
        .target(name: "ImmichKit", dependencies: ["ImmichAPI"]),
        .target(name: "ImmichUI", dependencies: ["ImmichKit"]),
        .testTarget(name: "ImmichKitTests", dependencies: ["ImmichKit", "ImmichUI"]),
    ]
)
