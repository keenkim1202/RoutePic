// swift-tools-version: 6.0
import PackageDescription

// A fourth package, where PLAN.md §10.1 settled on two plus feature folders.
// The exception is deliberate: the job state machine, quota ledger and fallback
// policy are pure logic with no UI, and they decide whether a user gets charged
// for a failed generation. That belongs behind its own test suite rather than
// inside an app-target folder.
let package = Package(
    name: "GenerationKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GenerationKit", targets: ["GenerationKit"]),
    ],
    dependencies: [
        .package(path: "../ShapeKit"),
    ],
    targets: [
        .target(name: "GenerationKit", dependencies: ["ShapeKit"]),
        .testTarget(name: "GenerationKitTests", dependencies: ["GenerationKit"]),
    ]
)
