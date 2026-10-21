// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxAgentManagement",
    platforms: [.macOS(.v26)],
    products: [.library(name: "RxAgentManagement", targets: ["RxAgentManagement"])],
    targets: [
        .target(name: "RxAgentManagement"),
        .testTarget(name: "RxAgentManagementTests", dependencies: ["RxAgentManagement"])
    ]
)
