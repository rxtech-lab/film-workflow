# What's New, User Guide, and TipKit

**Status:** Part E (TipKit) is implemented. Parts A–D remain a design spec.
**Scope:** three related discoverability features — a What's New sheet with unread feature cards, a
bundled multi-language User Guide, and TipKit popovers on the controls users get stuck on.

## Why

The app has shipped a great deal that never surfaces in the UI: the unified agent runtime, caption
transcription with four providers plus on-device WhisperKit, caption translation, the embedded
Remotion runtime, an MCP server, Lyria music, multi-speaker TTS, and image generation. Today none of
it is discoverable from inside the app. There is no What's New sheet, no help window, no onboarding,
and no bundled documentation — the only release notes live in the Sparkle appcast
(`scripts/ci/generate-appcast.sh`), which a user sees only if they happen to run an update.

The sibling app at `../RxCode` already solves all three problems. This document adapts its patterns
to this codebase's conventions. **Where the two apps differ, this document wins** — notably
persistence (this app has no `@AppStorage`), markdown rendering (this app already links `Textual`),
and the help window (a real macOS `Window` scene here, a sheet there).

## Contents

- [Part A — What's New feature cards](#part-a--whats-new-feature-cards)
- [Part B — Showing unread features](#part-b--showing-unread-features)
- [Part C — The User Guide window](#part-c--the-user-guide-window)
- [Part D — Bundled markdown docs and multi-language support](#part-d--bundled-markdown-docs-and-multi-language-support)
- [Part E — TipKit](#part-e--tipkit)
- [Localization checklist](#localization-checklist)

### New files at a glance

```
film-workflow/
  config/WhatsNewStore.swift            Part A — seen-slug persistence
  views/whatsnew/WhatsNewFeature.swift  Part A — the card catalog
  views/whatsnew/WhatsNewSheet.swift    Part B — the carousel sheet
  views/help/UserGuideSection.swift     Part C — section enum (filename + deep-link token)
  views/help/UserGuideView.swift        Part C — NavigationSplitView + markdown detail
  views/help/BundledMarkdownDocument.swift  Part D — locale-aware loader
  views/tips/FilmWorkflowTips.swift     Part E — the tip catalog
  Resources/user_manual_*.md            Part D — the guide content (already written)
```

Edited: `film_workflowApp.swift` (Help menu, User Guide window, `Tips.configure`), `ContentView.swift`
(launch presentation, iOS sheet, badge), `config/AppNavigation.swift` (deep-link field), and the
settings/tab views that gain a `.popoverTip`.

The app target uses `PBXFileSystemSynchronizedRootGroup` (`project.pbxproj:44-60`), so **new `.swift`
files under `film-workflow/` need no `project.pbxproj` edit**. Resources are a different story — see
[Bundling](#bundling-verify-this-first).

---

## Part A — What's New feature cards

### The model

`film-workflow/views/whatsnew/WhatsNewFeature.swift`:

```swift
import SwiftUI

/// A single "What's New" card.
///
/// `slug` is a stable, hand-authored identifier — never derived from a version
/// number. The seen-set is the only source of truth, so adding a card with a
/// fresh slug in any build surfaces exactly that card and nothing else.
struct WhatsNewFeature: Identifiable {
    let slug: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// SF Symbol shown in the card's icon tile.
    let icon: String
    let highlights: [Highlight]
    /// Optional guide page the card's "Learn more" link opens.
    let guideSection: UserGuideSection?

    var id: String { slug }

    struct Highlight {
        let icon: String
        let text: LocalizedStringKey
    }
}
```

Rules that matter:

- **Slugs are permanent.** Changing a slug re-shows the card to everyone who already dismissed it.
  Fixing a typo in a title is free; renaming `captions` to `caption` is not.
- **Never gate on version.** There is deliberately no `sinceVersion` field. A user who skips three
  releases sees all three releases' cards on their next launch, which is the desired behaviour.
- **`LocalizedStringKey`, not `String`.** Xcode's string extraction picks these literals up into
  `film-workflow/Localizable.xcstrings` automatically, the same way `Tabs.displayName`
  (`config/Tabs.swift:31`) and `AgentBackend.displayName` (`clients/agent/AgentBackend.swift:35`)
  already work. Do not build them with interpolation.
- **Order is presentation order.** Append new cards to the end of `all`.

### The seeded catalog

`static let all` in the same file, oldest first. These eight cards cover what has shipped and is
currently invisible:

```swift
    static let all: [WhatsNewFeature] = [
        WhatsNewFeature(
            slug: "lyria-music",
            title: "Generate music from a prompt",
            subtitle: "Describe the track you want and Lyria writes and performs it, with an optional song structure and lyrics.",
            icon: "music.note",
            highlights: [
                Highlight(icon: "text.badge.plus", text: "Build a prompt from genre, mood, instruments and tempo instead of writing one by hand."),
                Highlight(icon: "list.bullet.indent", text: "Lay out verses, choruses and bridges, and edit the lyrics line by line."),
                Highlight(icon: "square.and.arrow.down", text: "Play takes back in the app and export the ones you keep.")
            ],
            guideSection: .music
        ),
        WhatsNewFeature(
            slug: "narrative-tts",
            title: "Turn a script into narration",
            subtitle: "Multi-speaker text-to-speech with Azure and Gemini voices, stitched into one track.",
            icon: "text.book.closed",
            highlights: [
                Highlight(icon: "person.2", text: "Assign a different voice to each speaker and preview any voice before committing."),
                Highlight(icon: "curlybraces", text: "Shortcodes control pauses, emphasis and delivery inline in the script."),
                Highlight(icon: "waveform", text: "Segments are stitched into a single narration file automatically.")
            ],
            guideSection: .narrative
        ),
        WhatsNewFeature(
            slug: "captions",
            title: "Captions from your audio",
            subtitle: "Transcribe with Azure, OpenAI, Gemini, or entirely on device with WhisperKit — then export SRT or VTT.",
            icon: "captions.bubble",
            highlights: [
                Highlight(icon: "lock.shield", text: "WhisperKit runs on device, so audio never leaves your Mac."),
                Highlight(icon: "text.alignleft", text: "Align captions against an existing narration script so the wording matches exactly."),
                Highlight(icon: "square.and.arrow.up", text: "Export SRT or VTT, or fix timings in the retime sheet.")
            ],
            guideSection: .captions
        ),
        WhatsNewFeature(
            slug: "caption-translation",
            title: "Translate captions",
            subtitle: "Translate a caption track with Apple's on-device translation or with your AI provider.",
            icon: "character.bubble",
            highlights: [
                Highlight(icon: "iphone", text: "Apple Translation runs locally once you have the language pair installed."),
                Highlight(icon: "sparkles", text: "Or route it through your AI provider when you need context-aware wording."),
                Highlight(icon: "book.closed", text: "Glossary terms keep names and jargon consistent across languages.")
            ],
            guideSection: .captions
        ),
        WhatsNewFeature(
            slug: "image-generation",
            title: "Generate reference images",
            subtitle: "Produce stills for storyboards and thumbnails without leaving the app.",
            icon: "photo.on.rectangle.angled",
            highlights: [
                Highlight(icon: "text.cursor", text: "Iterate on a prompt and keep every generation in the project."),
                Highlight(icon: "rectangle.stack", text: "Generated images stay attached to the project that made them.")
            ],
            guideSection: .imageGeneration
        ),
        WhatsNewFeature(
            slug: "remotion-studio",
            title: "Render video with Remotion",
            subtitle: "A full Remotion runtime ships inside the app — no Node install, no terminal.",
            icon: "film.stack",
            highlights: [
                Highlight(icon: "shippingbox", text: "The runtime installs itself on first use and is signed with the hardened runtime."),
                Highlight(icon: "play.rectangle", text: "Preview compositions in Remotion Studio inside the app window."),
                Highlight(icon: "chevron.left.forwardslash.chevron.right", text: "Edit the composition's TSX source directly when you need to.")
            ],
            guideSection: .remotion
        ),
        WhatsNewFeature(
            slug: "agent-runtime",
            title: "An agent that drives the app",
            subtitle: "Ask for the work in plain language and the agent operates your projects for you.",
            icon: "sparkles",
            highlights: [
                Highlight(icon: "cpu", text: "Runs on Apple Intelligence, an OpenAI-compatible model, Claude Code, or Codex."),
                Highlight(icon: "square.on.square", text: "Each thread targets a project, so several conversations can run at once."),
                Highlight(icon: "checkmark.shield", text: "Changes that touch your work arrive as proposals you review before they apply.")
            ],
            guideSection: .agent
        ),
        WhatsNewFeature(
            slug: "mcp-server",
            title: "Drive the app from your own tools",
            subtitle: "An MCP server exposes the app's projects and generators to external clients.",
            icon: "network",
            highlights: [
                Highlight(icon: "power", text: "Turn it on in Settings › MCP Server; a bearer token is generated for you."),
                Highlight(icon: "wrench.and.screwdriver", text: "Tools cover projects, captions, generation and Remotion."),
                Highlight(icon: "lock", text: "Bound to localhost unless you explicitly allow other machines on the network.")
            ],
            guideSection: .mcpServer
        )
    ]
```

### Persistence

**Follow this app's idiom, not RxCode's.** RxCode uses a workspace-namespaced `UserDefaults` wrapper
that does not exist here. This app has no `@AppStorage` anywhere; every setting is a
`@MainActor @Observable final class` singleton whose properties write through to
`UserDefaults.standard` on `didSet` — see `config/MCPSettings.swift:14-39,56-64` and
`config/CaptionSettings.swift`. `WhatsNewStore` is that same shape.

`film-workflow/config/WhatsNewStore.swift`:

```swift
import Foundation
import Observation
import SwiftUI

/// Which What's New cards the user has already seen.
///
/// Same shape as `MCPSettings` and `CaptionSettings`: an `@Observable`
/// singleton mirroring `UserDefaults`, so views observe it directly and
/// nothing has to thread a binding through.
@MainActor
@Observable
final class WhatsNewStore {
    static let shared = WhatsNewStore()

    /// Slugs already shown. A `Set` rather than an array because order carries
    /// no meaning and membership is the only question ever asked — note this is
    /// why `@AppStorage` is unusable here, it cannot hold a `Set`.
    private(set) var seenSlugs: Set<String> = []

    /// Shipped cards the user has not seen, in catalog order.
    var unseenFeatures: [WhatsNewFeature] {
        WhatsNewFeature.all.filter { !seenSlugs.contains($0.slug) }
    }

    var unreadCount: Int { unseenFeatures.count }

    private init() {
        seenSlugs = Set(UserDefaults.standard.stringArray(forKey: Keys.seenSlugs) ?? [])
    }

    func markSeen(_ slug: String) {
        markSeen([slug])
    }

    func markSeen<S: Sequence>(_ slugs: S) where S.Element == String {
        var changed = false
        for slug in slugs where seenSlugs.insert(slug).inserted {
            changed = true
        }
        guard changed else { return }
        UserDefaults.standard.set(Array(seenSlugs), forKey: Keys.seenSlugs)
    }

    /// Marks the whole catalog seen. Used on a first-ever launch so a new
    /// install is not greeted with a backlog of things that are only "new"
    /// relative to a version they never ran.
    func markAllSeen() {
        markSeen(WhatsNewFeature.all.map(\.slug))
    }

    /// Records the install and reports whether this is the first ever launch.
    ///
    /// Called once at startup. There is no onboarding flag in this app to key
    /// off, so the marker is the app version stored on first run.
    func registerLaunchAndCheckIsFirstEver() -> Bool {
        let defaults = UserDefaults.standard
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard defaults.string(forKey: Keys.installedVersion) == nil else {
            defaults.set(current, forKey: Keys.installedVersion)
            return false
        }
        defaults.set(current, forKey: Keys.installedVersion)
        markAllSeen()
        return true
    }

    private enum Keys {
        static let seenSlugs = "whatsNew.seenSlugs"
        static let installedVersion = "whatsNew.installedVersion"
    }
}
```

> **Existing installs.** Everyone already running the app has no `whatsNew.installedVersion` key, so
> the first build carrying this code treats them as a first-ever launch and marks all eight seed
> cards seen — nobody gets a backlog on upgrade, and the mechanism starts clean from the ninth card
> onward. If you would rather show the seed cards to existing users, drop the `markAllSeen()` call
> from `registerLaunchAndCheckIsFirstEver()` for one release only, then restore it. Decide this
> before shipping; it cannot be changed retroactively.

---

## Part B — Showing unread features

Three surfaces: automatic presentation at launch, a persistent unread badge, and manual re-entry
from Settings. The badge is the piece RxCode does not have.

### The sheet

`film-workflow/views/whatsnew/WhatsNewSheet.swift` — a carousel of one card at a time.

```swift
struct WhatsNewSheet: View {
    /// The batch to present, captured by the caller so the array cannot shrink
    /// underneath the sheet as cards are marked seen mid-flow.
    let features: [WhatsNewFeature]
    var onDismiss: () -> Void

    @State private var store = WhatsNewStore.shared
    @State private var selectedIndex = 0

    private var isLastSlide: Bool { selectedIndex >= features.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            cardStack
            pageIndicator.padding(.top, 18)
            primaryButton.padding(.vertical, 20)
        }
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
        .onAppear { if features.isEmpty { onDismiss() } }
    }
```

The carousel — cross-fade plus a small parallax offset, no `TabView`, so it behaves identically on
both platforms:

```swift
    private var cardStack: some View {
        ZStack {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                featureCard(feature)
                    .opacity(selectedIndex == index ? 1 : 0)
                    .scaleEffect(selectedIndex == index ? 1 : 0.96)
                    .offset(x: CGFloat(index - selectedIndex) * 60)
                    .allowsHitTesting(selectedIndex == index)
            }
        }
        .animation(.snappy(duration: 0.42), value: selectedIndex)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { markSeen(at: selectedIndex) }
        .onChange(of: selectedIndex) { _, new in markSeen(at: new) }
    }

    private func markSeen(at index: Int) {
        guard features.indices.contains(index) else { return }
        store.markSeen(features[index].slug)
    }

    private func advance() {
        if isLastSlide { dismiss() } else { selectedIndex += 1 }
    }

    private func dismiss() {
        // Mark the entire batch, not just what was paged through: closing early
        // still counts as "you were shown these".
        store.markSeen(features.map(\.slug))
        onDismiss()
    }
```

Card body: an icon tile (SF Symbol on an accent-tinted rounded rect), title, subtitle, then the
highlight rows in a grouped container. Use `Color.accentColor` and the standard material
backgrounds — this app has no theme struct equivalent to RxCode's `ClaudeTheme`, so do not invent
one. When `feature.guideSection` is non-nil, add a "Learn more" button below the highlights that
opens the guide at that section (Part C).

Page indicator: one capsule per feature, the selected one widened to 24pt, hidden entirely when
there is a single card. `.accessibilityHidden(true)` — the button label already conveys position.

Primary button: `"Next"` until the last card, then `"Got it"`.

### Automatic presentation at launch

In `ContentView`, gated so a first-ever launch never shows it:

```swift
    @State private var whatsNew = WhatsNewStore.shared
    @State private var whatsNewBatch: [WhatsNewFeature] = []
    @State private var showWhatsNew = false

    // ...
    .task {
        guard !whatsNew.registerLaunchAndCheckIsFirstEver() else { return }
        let unseen = whatsNew.unseenFeatures
        guard !unseen.isEmpty else { return }
        whatsNewBatch = unseen   // captured before presenting — see WhatsNewSheet.features
        showWhatsNew = true
    }
    .sheet(isPresented: $showWhatsNew) {
        WhatsNewSheet(features: whatsNewBatch) { showWhatsNew = false }
    }
```

`.task` (not `.onAppear`) so it runs once per scene activation, next to the existing
`MCPServer.shared.bootstrap` task in `film_workflowApp.swift:53-55`.

### The unread badge

`unreadCount` drives every unread affordance. Zero means no badge at all — never render "0".

- **macOS Help menu**: the "What's New" item's title carries the count, since `Button` in a
  `CommandGroup` has no badge modifier:
  ```swift
  Button(whatsNew.unreadCount > 0 ? "What's New (\(whatsNew.unreadCount))" : "What's New") { … }
  ```
  Note this string is interpolated and so needs an explicit entry in the string catalog with a
  `%lld` placeholder; keep the zero case as a separate plain key.
- **Settings row**: a `Text("\(count)")` in a `Capsule().fill(.tint)` on the trailing edge of the
  What's New row, before the chevron.
- **iOS**: `.badge(whatsNew.unreadCount)` on the Settings `Tab` in `ContentView.swift:38`. SwiftUI
  already hides a zero badge, so no conditional is needed there.

### Manual re-entry from Settings

A row in a new "About" section of `SettingsView` opening `WhatsNewSheet(features: WhatsNewFeature.all)` —
**the whole catalog, not just unseen**, because this is a deliberate "show me everything" action.
Presenting it still marks everything seen, which clears the badge; that is intended.

`SettingsView` is a `TabView` (`views/settings/SettingsView.swift:8-32`); add the rows to a new
`AboutSettingsView` tab with a matching `AppNavigation.SettingsSection.about` case rather than
wedging them into an existing pane.

---

## Part C — The User Guide window

### Presentation differs per platform

**macOS: a real `Window` scene**, not a sheet. The reasoning is the same one written up for the
agent window at `film_workflowApp.swift:75-80` — there is exactly one User Guide, so a `Window`
rather than a `WindowGroup` means reopening raises the existing window instead of minting another,
and it can stay open beside the app while the user follows along.

```swift
// film-workflow/views/help/UserGuideView.swift
nonisolated enum UserGuideWindowID {
    static let value = "user-guide"
}

// film_workflowApp.swift, next to Window("Agent", …)
Window("User Guide", id: UserGuideWindowID.value) {
    UserGuideView()
}
.defaultSize(width: 900, height: 680)
```

**iOS: a `.sheet`**, since the platform has no second scene — the same split the app already makes
for the agent (`ContentView.swift:32-37`).

### The Help menu

macOS replaces the entire Help menu:

```swift
CommandGroup(replacing: .help) {
    Button("Film Workflow User Guide") {
        openWindow(id: UserGuideWindowID.value)
    }
    .keyboardShortcut("?", modifiers: .command)

    Button(whatsNew.unreadCount > 0 ? "What's New (\(whatsNew.unreadCount))" : "What's New") {
        // present WhatsNewSheet with WhatsNewFeature.all
    }
}
```

`replacing:` rather than `after:` **is required.** The stock Help menu looks for a Help Book that
this app does not ship and reports "Help isn't available for Film Workflow" (未找到“Film Workflow”的
帮助) when selected. Leaving the default item in place is a visible bug, not a cosmetic one — this is
documented in `../RxCode/RxCode/App/DocumentationCommands.swift`, which hit exactly this.

Place it alongside the existing `CommandGroup(after: .appInfo)` and `CommandGroup(after: .toolbar)`
blocks at `film_workflowApp.swift:59-71`.

### Deep linking to a section

Reuse `AppNavigation` (`config/AppNavigation.swift`) — it already exists for exactly this ("let a
view deep inside one tab send the user somewhere else") and already has a consume-once convention in
`pendingSettingsFocus`.

```swift
// config/AppNavigation.swift
/// The guide page to open next. Consumed by `UserGuideView` once shown, so
/// reopening the guide later lands on wherever the user last was.
var pendingUserGuideSection: UserGuideSection?

func showUserGuide(_ section: UserGuideSection = .overview) {
    pendingUserGuideSection = section
    #if !os(macOS)
        showUserGuideSheet = true
    #endif
}
```

On macOS the caller must also `openWindow(id: UserGuideWindowID.value)` from the environment — the
same caveat already documented on `showCaptionSettings` (`AppNavigation.swift:51-53`), because a
model object cannot raise a window.

Worth wiring at least these: the caption settings' Whisper model list → `.captions`, the MCP
settings pane → `.mcpServer`, the Remotion runtime-install banner → `.remotion`, and each What's New
card's "Learn more" → its `guideSection`.

### Layout

```swift
struct UserGuideView: View {
    @State private var navigation = AppNavigation.shared
    @State private var selection: UserGuideSection = .overview
    private let documents: [UserGuideSection: BundledMarkdownDocument]

    init() {
        // Every section is loaded up front: the files are a few KB each and
        // this keeps the sidebar titles (which come from each file's H1)
        // correct before anything is selected.
        documents = Dictionary(uniqueKeysWithValues: UserGuideSection.allCases.map {
            ($0, BundledMarkdownDocument.load(baseName: $0.resourceBaseName,
                                              fallbackTitle: $0.fallbackTitle))
        })
    }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .task(id: navigation.pendingUserGuideSection) {
            guard let requested = navigation.pendingUserGuideSection else { return }
            selection = requested
            navigation.pendingUserGuideSection = nil   // consume once
        }
    }
```

Sidebar rows are SF Symbol + the document's `title` (its H1, so translated content produces a
translated sidebar for free). Detail is a `ScrollView` of rendered markdown, `maxWidth: 760`,
centred, 32pt horizontal padding.

**There is no search.** The guide is eight pages; a sidebar is enough. Adding search is explicitly
out of scope — say so in review rather than adding it opportunistically.

---

## Part D — Bundled markdown docs and multi-language support

### Format: `.md`, not `.mdx`

The guide pages are plain GitHub-flavoured Markdown. There is no MDX parser for Swift, and MDX's
defining feature — embedding JSX components in prose — has no meaning in a native renderer that has
no JSX runtime to mount them into. If the same content is ever published to the marketing site,
`website/` is where `.mdx` belongs; the app reads `.md`.

Files carry **no frontmatter**. A page opens with its `# ` H1, and that H1 is the title used in the
sidebar and the window. Title metadata in two places drifts; one place cannot.

### Layout on disk

Flat, in `film-workflow/Resources/`:

```
user_manual_overview.md            user_manual_overview_zh_CN.md
user_manual_music.md               user_manual_music_zh_CN.md
user_manual_narrative.md           user_manual_narrative_zh_CN.md
user_manual_captions.md            user_manual_captions_zh_CN.md
user_manual_image_generation.md    user_manual_image_generation_zh_CN.md
user_manual_remotion.md            user_manual_remotion_zh_CN.md
user_manual_agent.md               user_manual_agent_zh_CN.md
user_manual_mcp_server.md          user_manual_mcp_server_zh_CN.md
```

**Locale is a filename suffix — not `.lproj` folders, and not `Localizable.xcstrings`.** Long-form
prose in a string catalog is unreviewable and merges badly; and `.lproj` would fight the
synchronized-group setup. The suffix scheme keeps a translation next to its source and lets a
missing translation fall back silently.

### The section enum

`film-workflow/views/help/UserGuideSection.swift` — the `rawValue` is simultaneously the filename
stem and the deep-link token:

```swift
enum UserGuideSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case music
    case narrative
    case captions
    case imageGeneration = "image_generation"
    case remotion
    case agent
    case mcpServer = "mcp_server"

    var id: String { rawValue }

    var resourceBaseName: String { "user_manual_\(rawValue)" }

    /// Shown only if the markdown file is missing or has no H1 — the real title
    /// comes from the document, so it is translated along with the content.
    var fallbackTitle: String {
        switch self {
        case .overview: "Overview"
        case .music: "Music"
        case .narrative: "Narration"
        case .captions: "Captions"
        case .imageGeneration: "Image Generation"
        case .remotion: "Remotion"
        case .agent: "Agent"
        case .mcpServer: "MCP Server"
        }
    }

    var icon: String {
        switch self {
        case .overview: "sparkle"
        case .music: "music.note"
        case .narrative: "text.book.closed"
        case .captions: "captions.bubble"
        case .imageGeneration: "photo.on.rectangle.angled"
        case .remotion: "film.stack"
        case .agent: "sparkles"
        case .mcpServer: "network"
        }
    }
}
```

Icons deliberately match `Tabs.systemImage` (`config/Tabs.swift:40-50`) so the guide sidebar reads as
the same app as the tab bar.

`remotion` is macOS-only in the app. Keep the case on both platforms and keep the page — an iOS user
reading about what the Mac app does is fine — but the page must open by saying it is macOS-only.

> **Pending: a `videoGen` case.** A **VideoGen** tab was added to `config/Tabs.swift` and
> `ContentView.swift` on this branch after these pages were written, and does not compile yet
> (`models/AgentTarget.swift:122` calls a `MCPProjectHandlers.fetchVideo` that does not exist).
> It is therefore deliberately absent from `UserGuideSection` and from the tab list in
> `user_manual_overview.md`. When that work lands, add the enum case, write
> `user_manual_video_generation.md` and its `_zh_CN` counterpart, and add the tab to the Overview
> page's list in **both** languages.

### The loader

`film-workflow/views/help/BundledMarkdownDocument.swift`. Adapted from
`../RxCode/RxCode/Views/UserManualView.swift:177-252`.

```swift
struct BundledMarkdownDocument {
    let title: String
    let content: String

    static func load(baseName: String, fallbackTitle: String, bundle: Bundle = .main) -> Self {
        for name in localizedResourceNames(for: baseName) {
            guard let url = bundle.url(forResource: name, withExtension: "md"),
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return Self(title: h1(in: content) ?? fallbackTitle, content: content)
        }
        return missing(title: fallbackTitle)
    }

    /// A missing page renders as a page saying so. It must never crash or show
    /// an empty pane — a dropped translation is a content bug, not a fatal one.
    static func missing(title: String) -> Self {
        Self(title: title, content: "# \(title)\n\nThis section of the user guide could not be loaded.")
    }

    /// The document's first `# ` heading, which is its display title.
    private static func h1(in content: String) -> String? {
        content.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { return nil }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }.first
    }

    /// Candidate filenames, most specific locale first, bare base name last.
    private static func localizedResourceNames(for baseName: String) -> [String] {
        var names: [String] = []
        func append(_ name: String) {
            guard !names.contains(name) else { return }
            names.append(name)
        }

        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            let language = locale.language.languageCode?.identifier
            let script = locale.language.script?.identifier
            let region = locale.region?.identifier

            // Exact tag first: zh-Hans-CN -> user_manual_x_zh_Hans_CN
            append("\(baseName)_\(identifier.replacingOccurrences(of: "-", with: "_"))")

            if language == "zh" {
                // Chinese needs a script/region collapse: the split that matters
                // is Simplified vs Traditional, which the bare language code
                // cannot express.
                if script == "Hant" || region == "HK" || region == "MO" || region == "TW" {
                    append("\(baseName)_zh_HK")
                } else {
                    append("\(baseName)_zh_CN")
                }
            } else if let language {
                append("\(baseName)_\(language)")
            }
        }

        append(baseName)   // English source, always last
        return names
    }
}
```

Resolution walk-through, against the files that ship today:

| `Locale.preferredLanguages` | Candidates tried | Resolves to |
| --- | --- | --- |
| `en-US` | `_en_US`, `_en`, bare | `user_manual_captions.md` |
| `zh-Hans-CN` | `_zh_Hans_CN`, `_zh_CN`, bare | `user_manual_captions_zh_CN.md` |
| `zh-Hant-TW` | `_zh_Hant_TW`, `_zh_HK`, bare | `user_manual_captions.md` (English — no Traditional files yet) |
| `ja-JP` | `_ja_JP`, `_ja`, bare | `user_manual_captions.md` (English fallback) |

### Rendering: reuse `Textual`

RxCode hand-rolled a markdown parser because it had no dependency to lean on. **This app must not.**
`Textual` 0.3.1 is already a resolved dependency and already renders agent messages at
`views/agent/AgentMessageRow.swift:50-52`. Use the same call:

```swift
import Textual

ScrollView {
    StructuredText(markdown: document.content)
        .textual.structuredTextStyle(.gitHub)
        .textual.textSelection(.enabled)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
}
```

Before writing pages that rely on them, confirm `Textual` renders tables and nested lists at the
version pinned in `Package.resolved`; if it does not, keep the guide to headings, paragraphs, lists,
code blocks, and links. The pages shipped alongside this document deliberately stay inside that
subset.

### Bundling — verified, no project changes needed

The three targets use `PBXFileSystemSynchronizedRootGroup` (`project.pbxproj:44-60`), which picks up
new files under `film-workflow/` automatically. This was worth checking for resources rather than
assuming, because today's Resources build phase lists two explicit folder references —
`appicon.icon` and `RemotionRuntime` (`project.pbxproj:242-251`) — both of which live at the repo
root, *outside* the synchronized group, which is exactly why they are listed by hand.

**Checked, and it works.** A macOS build with the sixteen `.md` files in place copies all sixteen to
`film-workflow.app/Contents/Resources/`, flat, under their own names. `Bundle.main.url(forResource:
"user_manual_captions_zh_CN", withExtension: "md")` therefore resolves with no `project.pbxproj`
edit and no folder reference.

To re-check after adding a page:

```sh
find "$BUILT_PRODUCTS_DIR" -name 'user_manual_*.md' | wc -l
```

### Authoring

**To add a guide page:**

1. Add a case to `UserGuideSection` with its `icon` and `fallbackTitle`. The `rawValue` is the
   filename stem — use `snake_case`, and never change it afterwards (it is a deep-link token).
2. Create `film-workflow/Resources/user_manual_<rawValue>.md`, starting with a `# ` H1.
3. Create `user_manual_<rawValue>_zh_CN.md`. Without it that page silently shows English to Chinese
   users, which is a worse failure than an obvious one — do not defer it.
4. If a What's New card should link to the page, set its `guideSection`.

**To add a language:**

1. Drop `user_manual_*_<locale>.md` for every section. The suffix must match what the resolver
   produces — bare language code for most languages (`_ja`, `_ko`, `_de`), and `_zh_CN` / `_zh_HK`
   for Chinese.
2. No code change is needed unless the language has a script split the bare code cannot express (as
   Chinese does), in which case add a collapse branch next to the `zh` one.
3. Add the language to `knownRegions` in `project.pbxproj` and translate
   `film-workflow/Localizable.xcstrings` too — the guide is only half the surface; the chrome around
   it (sidebar, menu items, buttons) comes from the string catalog.

**Content rules for the pages themselves:**

- Task-oriented. `## How to transcribe a video`, not `## The transcription subsystem`.
- Every claim must be readable out of the source. Do not document a button that does not exist; open
  the view file and check.
- Mark platform limits inline and early — Remotion and the Agent window are macOS-only.
- Short bullets over prose paragraphs. No screenshots: there is no asset pipeline for them and they
  rot immediately.
- Keep the Chinese page structurally parallel to the English one (same headings, same order), so a
  future edit can be applied to both without re-reading either.

---

## Part E — TipKit

**Implementation status:** complete. The app configures TipKit at launch, suppresses tips for UI
tests, and attaches the catalog below to the current controls. The attachment paths in this section
are the source of truth when views move.

### Configuration

In `film_workflowApp.init()`, alongside the existing `FileStorage.ensureDirectories()` and
`ProcessTreeKiller.killOrphans` calls:

```swift
import TipKit

try? Tips.configure([
    .displayFrequency(.immediate),
    .datastoreLocation(.applicationDefault),
])
```

`.immediate` because every tip below is capped at a single display; the frequency throttle exists for
apps that show tips repeatedly, which this one does not.

Deployment targets are `MACOSX_DEPLOYMENT_TARGET = 26.2` and `IPHONEOS_DEPLOYMENT_TARGET = 26.0`
(`project.pbxproj:401,500`), far above TipKit's macOS 14 / iOS 17 minimum, so no availability
guards are needed.

### The catalog

One namespaced enum, `film-workflow/views/tips/FilmWorkflowTips.swift`. Every tip is the same four
properties — title, message, image, and a single-display cap:

```swift
import SwiftUI
import TipKit

enum FilmWorkflowTips {
    struct AIProviderTip: Tip {
        var title: Text { Text("Set your AI provider once") }
        var message: Text? {
            Text("The endpoint, key and model here are what the agent, caption review and translation all use.")
        }
        var image: Image? { Image(systemName: "sparkles") }
        var options: [any TipOption] { Tips.MaxDisplayCount(1) }
    }
    // …one struct per tip, identical shape
}
```

Keep them alphabetical inside the enum and keep the shape uniform — a tip that grows rules or
parameters is a sign the explanation belongs in the User Guide instead.

### Where each tip attaches

Always `.popoverTip(_:arrowEdge:)` on the exact control being explained. Never a free-floating inline
`TipView`: a popover that points at the button answers "what is this?", a banner elsewhere on screen
does not.

| Area | Tip | Attach to |
| --- | --- | --- |
| Settings / config | `AIProviderTip` | the endpoint/key field, `views/settings/AIProviderSettingsView.swift` |
| Settings / config | `SubscriptionCreditsTip` | the credential-mode picker, `views/settings/AIProviderSettingsView.swift` |
| Settings / config | `AgentBackendTip` | the backend picker, `views/settings/AgentSettingsView.swift` |
| Settings / config | `WhisperModelTip` | the on-device model list, `views/settings/CaptionSettingsView.swift` |
| Settings / config | `MCPServerTip` | the enable toggle, `views/settings/MCPSettingsView.swift` |
| Buttons | `AgentButtonTip` | the toolbar agent button, `ContentView.swift` |
| Buttons | `GenerateMusicTip` | the generate button, `views/music/MusicTabView.swift` |
| Buttons | `TranscribeTip` | the transcribe button, `views/caption/CaptionTabView.swift` |
| Buttons | `RemotionStudioTip` | the create-composition/start-studio button, `views/remotion/RemotionParametersView.swift` |
| Agent | `AgentComposerTip` | the composer input where `@` selects a target, `views/agent/AgentComposer.swift` |
| Agent | `AgentProposalTip` | the proposal review header, `views/caption/CaptionAIReviewSheet.swift` |

Suggested copy, so the implementer is not inventing it:

- **AgentBackendTip** — "Choose where AI work runs" / "Apple Intelligence stays on device. The other
  backends use your provider settings or a CLI you already have installed."
- **WhisperModelTip** — "Transcribe without sending audio anywhere" / "Download a Whisper model once
  and captions are generated entirely on this device."
- **MCPServerTip** — "Let other tools drive this app" / "Turning this on starts a local server your
  editor or agent can connect to with the generated token."
- **SubscriptionCreditsTip** — "Use RxFilm credits" / "Sign in on the Account tab, choose RxFilm
  credits here, and add credits when needed. Each hosted generation deducts its actual usage."
- **AgentButtonTip** — "Ask the agent to do the work" / "Describe what you want in plain language;
  the agent operates the projects for you. ⌘⌥0 opens it any time." (macOS wording — drop the
  shortcut on iOS, where this is a tab.)
- **GenerateMusicTip** — "Generate a take" / "Each run keeps the previous takes, so you can compare
  before you commit to one."
- **TranscribeTip** — "Turn audio into captions" / "Pick a provider in Settings › Captions first —
  on-device Whisper needs a model downloaded."
- **RemotionStudioTip** — "Preview your composition" / "Remotion Studio runs inside the app; the
  runtime installs itself the first time you open it."
- **AgentComposerTip** — "Every thread targets one project" / "Type @ in the composer to switch the
  project. The thread keeps that target, so several conversations can work on different projects."
- **AgentProposalTip** — "Review before it applies" / "Caption edits from AI arrive here as
  proposals you can accept or reject one by one."

Attachment example:

```swift
Button {
    openWindow(id: AgentWindowID.value)
} label: {
    Label("Agent", systemImage: "sparkles")
}
.help("Open the agent")
.popoverTip(FilmWorkflowTips.AgentButtonTip(), arrowEdge: .top)
```

### Tests

TipKit popovers overlay the UI and swallow taps, which breaks `film-workflowUITests`. Suppress them
behind the same launch-argument check the UI tests already use:

```swift
if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
    Tips.hideAllTipsForTesting()
}
```

For manual QA, `Tips.showAllTipsForTesting()` re-arms everything without deleting the datastore.

---

## Localization checklist

The app ships `en` (source) and `zh-Hans` (`project.pbxproj:215-221`), with all strings in
`film-workflow/Localizable.xcstrings` — 888 keys today, of which **136 have no `zh-Hans` value**.
Everything added here lands in that same catalog.

Before shipping any part of this:

- [ ] Build once so Xcode extracts the new `LocalizedStringKey` literals from `WhatsNewFeature.all`,
      `WhatsNewSheet`, `UserGuideSection.fallbackTitle`, the Help menu items, and every tip.
- [ ] Fill in `zh-Hans` for all of them. A missing value falls back to English silently, which reads
      as a bug in a Chinese UI.
- [ ] The interpolated badge string ("What's New (%lld)") needs its placeholder checked in the
      catalog editor, not just typed.
- [ ] Every `user_manual_*.md` has a `_zh_CN` counterpart with the same heading structure.
- [ ] Product names stay untranslated — follow the `engineLabel` convention at
      `clients/agent/AgentBackend.swift:44-52` for "Claude Code", "Codex", "Remotion", "WhisperKit".
- [ ] Consider closing some of the pre-existing 136 gaps while the catalog is open.
