// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxRemotion",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RxRemotion", targets: ["RxRemotion"]),
        .library(name: "RxRemotionUI", targets: ["RxRemotionUI"]),
        .executable(name: "RxRemotionExample", targets: ["RxRemotionExample"]),
    ],
    targets: [
        .target(name: "RxRemotionPixels"),
        .target(name: "RxRemotion", dependencies: ["RxRemotionPixels"], resources: [.copy("Resources/Web"), .copy("Resources/Template")]),
        .target(name: "RxRemotionUI", dependencies: ["RxRemotion"]),
        .executableTarget(name: "RxRemotionExample", dependencies: ["RxRemotion", "RxRemotionUI"]),
        .testTarget(name: "RxRemotionTests", dependencies: ["RxRemotion"], resources: [.copy("Fixtures")]),
    ]
)
