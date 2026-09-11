import SwiftUI

/// Standalone entry point uses the same library transport and frame preview.
struct RemotionViewer: View {
    let project: RemotionProject
    let document: ProjectDocument
    @State private var player = FootagePlayer()

    var body: some View {
        let cell = FootageCell(id: project.id, title: project.name, subtitle: "", footage: project)
        FootageViewer(cell: cell, name: project.name, versions: [cell], onSelectVersion: { _ in },
                      player: player, document: document)
    }
}
