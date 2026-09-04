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
            path: "Tests"
        )
    ]
)
