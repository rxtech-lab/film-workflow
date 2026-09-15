import SwiftUI
import TipKit

/// The package owns the controls and their tips; the host configures TipKit's
/// datastore once for the app. Keep these IDs stable across copy changes.
enum FilmTemplateTip: String, Tip {
    case gallery, uploads, templateChoice, options, activity, refinement, editor, notes

    var id: String { "film.simple.\(rawValue)" }
    var title: Text { Text(copy.title) }
    var message: Text? { Text(copy.message) }
    var image: Image? { Image(systemName: copy.symbol) }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    func didPerform() { invalidate(reason: .actionPerformed) }

    private var copy: (title: LocalizedStringKey, message: LocalizedStringKey, symbol: String) {
        switch self {
        case .gallery:
            ("Let Simple mode build a first cut", "Pick a guided starting point, provide a brief and your footage, then review the plan. You can refine the result or continue in the editor.", "sparkles")
        case .uploads:
            ("Bring your own footage", "Add the clips, images or audio you want the film to use. You can also drag files into this area and remove any you don't need.", "square.and.arrow.down")
        case .templateChoice:
            ("Choose the direction for your film", "Compare the suggested templates and select one before continuing. The next step lets you review the choices for your film.", "rectangle.on.rectangle")
        case .options:
            ("Review the plan before building", "Check the suggested footage, music and other choices on this page. Build My Film starts assembling your first cut.", "checklist")
        case .activity:
            ("See what the agent is doing", "Open the live conversation to follow messages and tool activity during research, planning or building. Closing it leaves the work running.", "bubble.left.and.bubble.right")
        case .refinement:
            ("Ask for a change", "Try “make the opening shorter” or “use a calmer title.” Send your request when the agent is ready, then preview the updated cut.", "sparkles")
        case .editor:
            ("Take control of the details", "Open this film in the full editor to trim clips, adjust captions, add effects and render the finished sequence.", "slider.horizontal.3")
        case .notes:
            ("Review the latest build notes", "Open the agent's summary to see what was built or changed before asking for another refinement.", "text.alignleft")
        }
    }
}

extension View {
    func templateTip(_ tip: FilmTemplateTip, when eligible: Bool = true) -> some View {
        popoverTip(eligible ? tip : nil, arrowEdge: .top)
    }
}
