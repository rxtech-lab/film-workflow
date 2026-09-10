// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxVideoEditor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VideoEditorCore", targets: ["VideoEditorCore"]),
        .library(name: "VideoEditorUI", targets: ["VideoEditorUI"]),
    ],
    targets: [
        // Timeline model, editing operations, AVFoundation composition,
        // playback controller and export. No SwiftUI, no app coupling.
        .target(
            name: "VideoEditorCore",
            resources: [.copy("Resources/blank.mov")],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        // SwiftUI timeline, viewer and inspectors on top of the core.
        .target(
            name: "VideoEditorUI",
            dependencies: ["VideoEditorCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "VideoEditorCoreTests",
            dependencies: ["VideoEditorCore"]
        ),
    ]
)
