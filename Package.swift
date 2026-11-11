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
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ImmichAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            // Sources are generated ahead of time (not via the build plugin, which Xcode refuses to run
            // unattended without plugin validation). Regenerate with:
            //   swift package --allow-writing-to-package-directory generate-code-from-openapi --target ImmichAPI
            // The command plugin needs openapi.json and the config visible in the target, so they are not
            // excluded; SwiftPM prints a harmless "unhandled files" warning for them.
        ),
        .target(
            name: "ImmichKit",
            dependencies: [
                "ImmichAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .target(name: "ImmichUI", dependencies: ["ImmichKit"]),
        .testTarget(
            name: "ImmichKitTests",
            dependencies: [
                "ImmichAPI",
                "ImmichKit",
                "ImmichUI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
