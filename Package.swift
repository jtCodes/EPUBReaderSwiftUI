// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EPUBReaderSwiftUI",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "EPUBReaderSwiftUI",
            targets: ["EPUBReaderSwiftUI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/readium/swift-toolkit.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "EPUBReaderSwiftUI",
            dependencies: [
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
                .product(name: "ReadiumAdapterGCDWebServer", package: "swift-toolkit")
            ]
        ),
    ]
)
