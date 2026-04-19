// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "LinkFinder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "linkfinder", targets: ["LinkFinder"])
    ],
    targets: [
        .executableTarget(name: "LinkFinder")
    ]
)
