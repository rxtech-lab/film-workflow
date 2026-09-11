import UniformTypeIdentifiers

extension UTType {
    /// A film: a package directory holding the SwiftData store and every
    /// media file generated for it. Declared in the root `Info.plist` under
    /// `UTExportedTypeDeclarations`, extension `rxfilmstudio`.
    static let rxFilmStudioProject = UTType(exportedAs: "rxlab.film-workflow.project", conformingTo: .package)

    /// Drag payload for footage moving from the library onto the timeline.
    static let rxFootage = UTType(exportedAs: "rxlab.film-workflow.footage", conformingTo: .data)
}
