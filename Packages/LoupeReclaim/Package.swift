// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoupeReclaim",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LoupeReclaim", targets: ["LoupeReclaim"])],
    dependencies: [.package(path: "../LoupeCore"), .package(path: "../LoupeFS")],
    targets: [
        .target(name: "LoupeReclaim",
                dependencies: [.product(name: "LoupeCore", package: "LoupeCore"),
                               .product(name: "LoupeFS", package: "LoupeFS")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LoupeReclaimTests", dependencies: ["LoupeReclaim"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
