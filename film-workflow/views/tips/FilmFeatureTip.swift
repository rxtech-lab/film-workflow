import SwiftUI
import TipKit

/// Stable identities keep discovery history separate for each feature, even
/// when several controls (for example Render) teach the same workflow.
enum FilmFeatureTip: String, Tip {
    case simpleEngine, simpleLocation, simpleTimeline, liveActivity
    case chatTarget, chatThreads, chatNewThread, chatPin, chatEngine, chatThinking
    case marketplaceBrowse, marketplaceCategories, marketplacePreview
    case marketplaceSignIn, marketplaceBuy, marketplaceInstall, marketplaceInstalled
    case marketplaceAdd, marketplaceTemplate
    case inspectorTabs, generateImage, generateVideo, generateNarration, resumeVideo
    case remotionSource, remotionRender, sequenceRender, sequenceRemotion
    case captionTranslate, captionStyle, effectOrder, transitionDuration
    case newFootage, importMedia, importStorage, libraryMarketplace, libraryFilter, effectsBrowser

    var id: String { "film.feature.\(rawValue)" }
    var title: Text { Text(copy.title) }
    var message: Text? { Text(copy.message) }
    var image: Image? { Image(systemName: copy.symbol) }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }

    func didPerform() { invalidate(reason: .actionPerformed) }

    private var copy: (title: LocalizedStringKey, message: LocalizedStringKey, symbol: String) {
        switch self {
        case .simpleEngine:
            ("Choose your film's AI engine", "This engine researches, plans and builds your film. Resolve any setup message before continuing; you can switch engines later in the Agent window.", "cpu")
        case .simpleLocation:
            ("Keep your film together", "Choose a name and save location. The film project keeps your imported footage, edits and generated media together.", "folder")
        case .simpleTimeline:
            ("Jump to a shot", "Click a clip to pause and jump to its start. The highlighted shot follows the agent's latest edit as your film is built.", "timeline.selection")
        case .liveActivity:
            ("Follow the live conversation", "Messages and tool activity appear as the agent works. Expand a tool call for details; closing this panel lets the build continue.", "bubble.left.and.bubble.right")
        case .chatTarget:
            ("Choose what this chat works on", "Target the whole film or a specific library item. Each conversation remembers its own target.", "scope")
        case .chatThreads:
            ("Return to a conversation", "Switch between saved threads here. A dotted circle means work is running; a filled circle marks a finished reply you haven't seen.", "list.bullet")
        case .chatNewThread:
            ("Start a fresh conversation", "Create a separate thread for a new request. Your earlier conversations stay in the Threads menu.", "square.and.pencil")
        case .chatPin:
            ("Keep a conversation handy", "Pinned threads stay at the top of the Threads menu. Click again to unpin.", "pin")
        case .chatEngine:
            ("Pick an engine and model", "This choice applies to this conversation. Choose a model inside an engine's menu, or use Default to follow Settings.", "sparkles")
        case .chatThinking:
            ("Adjust the thinking level", "Choose how much reasoning this model uses. Higher levels can help with complex edits but may take longer.", "brain")
        case .marketplaceBrowse:
            ("Find something for your film", "Browse by kind in this sidebar, then use the search field to narrow the catalog. Open an item to preview it and see its price.", "storefront")
        case .marketplaceCategories:
            ("Narrow down this collection", "Choose a category within this kind. Search and category filters work together; All Categories clears this filter.", "line.3.horizontal.decrease")
        case .marketplacePreview:
            ("Try it before adding it", "Use the preview to inspect this item. Installing adds it to your library; Add to Film brings supported items into your open film.", "play.rectangle")
        case .marketplaceSignIn:
            ("Build your marketplace library", "Sign in to install free items or buy paid items with credits. You can browse and preview before signing in.", "person.crop.circle")
        case .marketplaceBuy:
            ("Buy once with credits", "The button shows this item's price. After purchase, install it to use it in your films.", "creditcard")
        case .marketplaceInstall:
            ("Download to your library", "Install this item on your Mac. It will be available from the editor's Marketplace library across your films.", "arrow.down.circle")
        case .marketplaceInstalled:
            ("Manage this download", "Open this menu to reveal the local files or uninstall the download. Purchased items can be installed again.", "checkmark.circle")
        case .marketplaceAdd:
            ("Bring this item into your film", "Add the installed item to the film in front. Then find it in the library and place footage on your timeline.", "plus.rectangle.on.folder")
        case .marketplaceTemplate:
            ("Build with this template", "The agent checks your film's footage, asks for anything missing and creates a new sequence using this template.", "film.stack")
        case .inspectorTabs:
            ("Inspect the selected item", "Tabs change with your selection. Footage settings control the source; Clip controls the selected timeline clip; Sequence controls the whole cut.", "slider.horizontal.3")
        case .generateImage:
            ("Create an image take", "Describe the image and set its options above, then generate. Earlier takes remain available in the library's Versions view.", "photo")
        case .generateVideo:
            ("Create a video take", "Set the prompt and clip options above, then generate. Each completed run is kept as another take in the library.", "video")
        case .generateNarration:
            ("Review before creating speech", "Set your script and voices, then open the transcript preview here. Start Generation in that preview creates a new narration take.", "waveform")
        case .resumeVideo:
            ("Recover a running generation", "Resume checks the video job already running at the provider and downloads it when ready.", "clock.arrow.circlepath")
        case .remotionSource:
            ("Inspect the composition source", "Open the source to review or edit the composition. Source changes refresh the live preview.", "doc.text")
        case .remotionRender:
            ("Turn the composition into video", "Render creates a video take of this composition. Previous renders stay in Versions so you can compare or export them.", "play.rectangle")
        case .sequenceRender:
            ("Export your finished sequence", "Choose video, audio, size and destination in the render sheet. Save a version inside the film or export to a folder.", "film.stack")
        case .sequenceRemotion:
            ("Prepare changed compositions", "Render the Remotion clips that need updating for this sequence's size. This prepares those clips without exporting the entire film.", "arrow.triangle.2.circlepath")
        case .captionTranslate:
            ("Add another language", "Choose a language and translation engine. Translations belong to the current transcript version; Update fills missing or outdated lines.", "character.bubble")
        case .captionStyle:
            ("Apply this style to timeline captions", "Style edits here set the project's defaults. Use this button to copy them to the caption clips already on the timeline.", "textformat")
        case .effectOrder:
            ("Control how effects combine", "Effects are applied in order. Move an effect earlier or later to change the result, or turn it off to compare.", "line.3.horizontal.decrease")
        case .transitionDuration:
            ("Set the transition's length", "Enter a duration in seconds and press Return. For a transition joining two clips, those clips move together until you remove it.", "arrow.left.and.right")
        case .newFootage:
            ("Add something to your film", "Create music, narration, captions, images, video or a composition here. Select the new item to configure it in the inspector.", "plus")
        case .importMedia:
            ("Use your own footage", "Import video, audio or images. You can also drop files into the library, then choose whether to copy them into the film.", "square.and.arrow.down")
        case .importStorage:
            ("Choose how files are stored", "Copy keeps the film portable. Reference saves disk space but needs the original file to stay in its current location.", "externaldrive")
        case .libraryMarketplace:
            ("Your installed marketplace items", "Switch to Marketplace to browse your downloads alongside this film's library. Add an item to the film before editing it.", "storefront")
        case .libraryFilter:
            ("Find footage in this library", "Filter by name and use the kind picker to narrow the list. Clear the filter to show everything again.", "magnifyingglass")
        case .effectsBrowser:
            ("Add effects and transitions", "Open the browser, then drag an effect onto a clip or a transition onto a clip edge. Adjust it in the inspector.", "fx")
        }
    }
}

extension View {
    /// Eligibility follows the actual control, so busy, hidden or unavailable
    /// actions do not teach a step the user cannot take yet.
    func filmTip(_ tip: FilmFeatureTip, when eligible: Bool = true, arrowEdge: Edge = .top) -> some View {
        popoverTip(eligible ? tip : nil, arrowEdge: arrowEdge)
    }
}
