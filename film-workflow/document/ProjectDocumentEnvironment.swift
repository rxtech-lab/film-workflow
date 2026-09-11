import SwiftUI

private struct ProjectDocumentKey: EnvironmentKey {
    static let defaultValue: ProjectDocument? = nil
}

private struct ProjectStorageKey: EnvironmentKey {
    static let defaultValue: ProjectStorage = ProjectStorage.ephemeralStorage()
}

extension EnvironmentValues {
    /// The film the current window is editing. Nil in the agent window,
    /// Settings, and previews.
    var projectDocument: ProjectDocument? {
        get { self[ProjectDocumentKey.self] }
        set { self[ProjectDocumentKey.self] = newValue }
    }

    /// File layout of the current film. Defaults to a throwaway package so
    /// previews and tests can still write files.
    var projectStorage: ProjectStorage {
        get { self[ProjectStorageKey.self] }
        set { self[ProjectStorageKey.self] = newValue }
    }
}
