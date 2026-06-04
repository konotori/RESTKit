// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RESTKit",
	platforms: [
		.iOS(.v13),
		.macOS(.v11)
	],
    products: [
        .library(
            name: "RESTKit",
            targets: ["RESTKit"]
        ),
    ],
    targets: [
        .target(
            name: "RESTKit"
        ),
        .testTarget(
            name: "RESTKitTests",
            dependencies: ["RESTKit"]
        ),
    ]
)
