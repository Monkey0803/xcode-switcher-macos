// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "XcodeSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XcodeSwitcher", targets: ["XcodeSwitcher"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "XcodeSwitcher",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "XcodeSwitcherTests",
            dependencies: ["XcodeSwitcher"],
            path: "Tests",
            linkerSettings: [
                // The test bundle links the app target and therefore Sparkle.
                // The Swift Build backend drops Sparkle.framework in the
                // products directory but only puts PackageFrameworks on the
                // bundle's rpath, so dyld cannot find it. This relative rpath
                // resolves the products directory for both backend layouts.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../"])
            ]
        )
    ]
)
