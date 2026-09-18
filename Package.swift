// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "XcodeSwitcher",
    // 5.9 的 PackageDescription 里没有 .v15，只有到 .v14 的枚举；
    // 字符串形式是官方为「枚举还没跟上」准备的写法，不必为此抬高 tools-version
    // （tools-version 6.0 会让 target 默认切到 Swift 6 语言模式，是另一个改动）。
    platforms: [.macOS("15.0")],
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
