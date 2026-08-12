// swift-tools-version:5.9
import PackageDescription

// Local mirror of https://github.com/sparkle-project/Sparkle.
//
// Upstream's Package.swift declares Sparkle as a *remote* binaryTarget, so every
// `xcodebuild` run — including CI, and including the iOS build that never links
// Sparkle — has to download Sparkle-for-Swift-Package-Manager.zip from GitHub
// Releases before package resolution can finish. When that download fails the
// whole build fails during resolution, before a single file is compiled.
//
// Vendoring the XCFramework makes resolution offline. To bump Sparkle, replace
// Sparkle.xcframework with the contents of the release's
// Sparkle-for-Swift-Package-Manager.zip and update SPARKLE_VERSION in
// scripts/ci/install-sparkle-tools.sh to match.
let sparkleVersion = "2.9.5"

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "Sparkle",
            targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            path: "Sparkle.xcframework"
        )
    ]
)
