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
        // Separate so the pure logic above keeps building and testing without
        // Apple's Stable Diffusion package, which is large and only the app
        // target actually needs.
        .library(name: "GenerationCoreML", targets: ["GenerationCoreML"]),
    ],
    dependencies: [
        .package(path: "../ShapeKit"),
        .package(
            url: "https://github.com/apple/ml-stable-diffusion.git",
            from: "1.1.0"
        ),
    ],
    targets: [
        .target(name: "GenerationKit", dependencies: ["ShapeKit"]),
        .target(
            name: "GenerationCoreML",
            dependencies: [
                "GenerationKit",
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ]
        ),
        .testTarget(name: "GenerationKitTests", dependencies: ["GenerationKit"]),
        .testTarget(name: "GenerationCoreMLTests", dependencies: ["GenerationCoreML"]),
    ]
)
