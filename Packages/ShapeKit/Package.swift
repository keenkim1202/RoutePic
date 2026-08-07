// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShapeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ShapeKit", targets: ["ShapeKit"]),
        .executable(name: "shapelab", targets: ["shapelab"]),
    ],
    targets: [
        .target(name: "ShapeKit"),
        .executableTarget(name: "shapelab", dependencies: ["ShapeKit"]),
        .testTarget(name: "ShapeKitTests", dependencies: ["ShapeKit"]),
    ]
)
