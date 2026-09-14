// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxFilmTemplates",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FilmTemplateKit", targets: ["FilmTemplateKit"]),
        .library(name: "JSONRenderUI", targets: ["JSONRenderUI"]),
        .library(name: "FilmTemplateUI", targets: ["FilmTemplateUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sirily11/swift-jsonschema-form", exact: "1.0.8"),
        .package(url: "https://github.com/sirily11/swift-json-schema", from: "1.0.2"),
    ],
    targets: [
        // Template catalog, wizard steps, intake schema and prompt text. No
        // SwiftUI and no app coupling, so the prompts and the schema can be
        // tested without a window.
        .target(
            name: "FilmTemplateKit",
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        // A SwiftUI renderer for the json-render spec format. The agent emits a
        // spec, the app renders it; nothing here knows about films.
        .target(
            name: "JSONRenderUI",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        // The wizard's pages. Every page is a plain view over data plus
        // callbacks so the app owns all the state and the services.
        .target(
            name: "FilmTemplateUI",
            dependencies: [
                "FilmTemplateKit",
                "JSONRenderUI",
                .product(name: "JSONSchemaForm", package: "swift-jsonschema-form"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(name: "FilmTemplateKitTests", dependencies: ["FilmTemplateKit"]),
        .testTarget(name: "JSONRenderUITests", dependencies: ["JSONRenderUI"]),
    ]
)
