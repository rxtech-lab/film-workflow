// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxVideoEffects",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VideoEffectsCore", targets: ["VideoEffectsCore"]),
        .library(name: "VideoEffectsUI", targets: ["VideoEffectsUI"]),
    ],
    targets: [
        .target(name: "VideoEffectsCore", resources: [.process("Resources")]),
        .target(name: "VideoEffectsUI", dependencies: ["VideoEffectsCore"],
                swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "VideoEffectsTests", dependencies: ["VideoEffectsCore"]),
    ]
)
