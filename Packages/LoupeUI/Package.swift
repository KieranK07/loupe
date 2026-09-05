// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoupeUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "LoupeUI", targets: ["LoupeUI"])],
    dependencies: [.package(path: "../LoupeCore")],
    targets: [
        // Deliberately does NOT depend on LoupeFS or LoupeTree. The UI renders
        // SunburstLayout values and nothing else; it has no route to a syscall.
        .target(name: "LoupeUI",
                dependencies: [.product(name: "LoupeCore", package: "LoupeCore")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LoupeUITests", dependencies: ["LoupeUI"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
