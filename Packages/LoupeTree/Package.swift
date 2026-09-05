// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoupeTree",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LoupeTree", targets: ["LoupeTree"])],
    dependencies: [.package(path: "../LoupeCore")],
    targets: [
        .target(name: "LoupeTree",
                dependencies: [.product(name: "LoupeCore", package: "LoupeCore")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LoupeTreeTests", dependencies: ["LoupeTree"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
