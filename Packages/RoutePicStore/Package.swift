// swift-tools-version: 6.0
import PackageDescription

// Named RoutePicStore, not StoreKit_Local: cross-review flagged that the
// original name collides with Apple's StoreKit, which this app also uses for
// subscriptions (DESIGN.md §8.3).
let package = Package(
    name: "RoutePicStore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RoutePicStore", targets: ["RoutePicStore"]),
    ],
    dependencies: [
        .package(path: "../ShapeKit"),
        .package(path: "../RouteKit"),
    ],
    targets: [
        .target(name: "RoutePicStore", dependencies: ["ShapeKit", "RouteKit"]),
        .testTarget(name: "RoutePicStoreTests", dependencies: ["RoutePicStore"]),
    ]
)
