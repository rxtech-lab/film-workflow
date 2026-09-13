import SwiftUI
import RxRemotion

struct RemotionMapSettingsView: View {
    @AppStorage(RemotionRenderPreferences.concurrencyKey) private var concurrency = 0
    @State private var enabled = false
    @State private var tileURL = ""
    @State private var attribution = ""
    @State private var minimumZoom = 0
    @State private var maximumZoom = 19
    @State private var allowsExport = false
    @State private var headerName = "Authorization"
    @State private var credential = ""
    @State private var additionalHeaders: [String: String] = [:]
    /// Why the tile provider isn't in effect yet, from `RemotionMapSettings.save`.
    @State private var message: String?
    /// Set once the form has been filled from the stored configuration, so the
    /// autosave can't write a blank provider over a saved one on first layout.
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Rendering") {
                Picker("Frames at a time", selection: $concurrency) {
                    Text("Automatic").tag(0)
                    ForEach(1...4, id: \.self) { count in Text("\(count)").tag(count) }
                }
                Text("Render more frames at once for faster exports. Higher settings use more memory. Changes apply to the next render.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Maps") {
                Text("MapKit maps are ready to use in Remotion compositions.")
            }
            Section("OpenStreetMap") {
                Toggle("Use a tile provider", isOn: $enabled)
                if enabled {
                    TextField("Tile URL", text: $tileURL, prompt: Text("https://provider.example/{z}/{x}/{y}.png"))
                    TextField("Attribution", text: $attribution)
                    Stepper("Minimum zoom: \(minimumZoom)", value: $minimumZoom, in: 0...maximumZoom)
                    Stepper("Maximum zoom: \(maximumZoom)", value: $maximumZoom, in: minimumZoom...22)
                    TextField("Credential header (optional)", text: $headerName)
                    SecureField("Credential value", text: $credential)
                    Text("Credentials are stored in Keychain and sent only to your tile provider.").font(.caption).foregroundStyle(.secondary)
                    Toggle("My provider permits automated movie exports", isOn: $allowsExport)
                    Text("Use a provider licensed for rendering. The public OpenStreetMap tile server is not available for automated exports.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        // No Save button: edits are committed on a short delay. Keyed on the
        // whole draft so a fresh keystroke replaces the pending write rather
        // than adding a Keychain round-trip and a preview reload per character.
        .task(id: draft) {
            guard hasLoaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persist()
        }
        .onAppear {
            defer { hasLoaded = true }
            guard let provider = RemotionMapSettings.configuration.openStreetMap else { return }
            enabled = true; tileURL = provider.tileURL; attribution = provider.attribution
            minimumZoom = provider.minimumZoom; maximumZoom = provider.maximumZoom; allowsExport = provider.allowsExport
            additionalHeaders = provider.headers
            if let key = provider.headers.keys.sorted().first {
                headerName = key; credential = additionalHeaders.removeValue(forKey: key) ?? ""
            }
        }
    }

    /// Every field the autosave watches, gathered so `task(id:)` can key on it.
    private var draft: RemotionConfiguration {
        // Only the map provider is edited here, so the rest of the stored
        // configuration is carried over rather than reset to its defaults.
        var config = RemotionMapSettings.configuration
        guard enabled else { config.openStreetMap = nil; return config }
        var values = additionalHeaders
        if !credential.isEmpty { values[headerName] = credential }
        config.openStreetMap = .init(tileURL: tileURL, attribution: attribution,
            minimumZoom: minimumZoom, maximumZoom: maximumZoom, allowsExport: allowsExport, headers: values)
        return config
    }

    private func persist() {
        let config = draft
        guard config != RemotionMapSettings.configuration else { message = nil; return }
        do {
            try RemotionMapSettings.save(config)
            message = nil
        } catch {
            // An incomplete provider fails validation, which is the normal state
            // halfway through typing a tile URL — so this reads as guidance, not
            // as a failure, and the stored configuration is left alone.
            message = error.localizedDescription
        }
    }
}
