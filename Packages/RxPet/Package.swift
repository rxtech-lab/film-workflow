// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RxPet", platforms: [.macOS(.v26)], products: [.library(name: "RxPet", targets: ["RxPet"])], targets: [
    .target(name: "RxPet", resources: [.process("Resources")]),
    .testTarget(name: "RxPetTests", dependencies: ["RxPet"])
])
