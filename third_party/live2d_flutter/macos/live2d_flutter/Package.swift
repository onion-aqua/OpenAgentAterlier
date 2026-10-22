// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "live2d_flutter",
    platforms: [.macOS("10.15")],
    products: [
        .library(name: "live2d-flutter", targets: ["live2d_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "live2d_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
