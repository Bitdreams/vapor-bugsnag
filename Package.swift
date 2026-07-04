// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vapor-bugsnag",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "BugsnagNotifier", targets: ["BugsnagNotifier"]),
        .library(name: "BugsnagVapor", targets: ["BugsnagVapor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),
    ],
    targets: [
        .target(name: "BugsnagNotifier"),
        .target(
            name: "BugsnagVapor",
            dependencies: [
                "BugsnagNotifier",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "BugsnagNotifierTests",
            dependencies: ["BugsnagNotifier"]
        ),
        .testTarget(
            name: "BugsnagVaporTests",
            dependencies: [
                "BugsnagVapor",
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
