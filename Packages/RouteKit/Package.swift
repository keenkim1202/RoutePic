// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RouteKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RouteKit", targets: ["RouteKit"]),
    ],
    dependencies: [
        .package(path: "../ShapeKit"),
    ],
    targets: [
        .target(name: "RouteKit", dependencies: ["ShapeKit"]),
        .testTarget(name: "RouteKitTests", dependencies: ["RouteKit"]),
    ]
)
