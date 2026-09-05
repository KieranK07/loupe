// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoupeFS",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LoupeFS", targets: ["LoupeFS"])],
    dependencies: [.package(path: "../LoupeCore"), .package(path: "../LoupeTree")],
    targets: [
        .target(name: "CLoupeFS"),
        .target(name: "LoupeFS",
                dependencies: ["CLoupeFS",
                               .product(name: "LoupeCore", package: "LoupeCore"),
                               .product(name: "LoupeTree", package: "LoupeTree")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LoupeFSTests", dependencies: ["LoupeFS"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
