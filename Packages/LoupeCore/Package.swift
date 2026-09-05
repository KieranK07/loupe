// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoupeCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LoupeCore", targets: ["LoupeCore"])],
    targets: [
        .target(name: "LoupeCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
