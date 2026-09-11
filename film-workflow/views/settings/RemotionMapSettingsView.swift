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
    @State private var message: String?

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
            }
            Button("Save Map Settings") {
                do {
                    var values = additionalHeaders
                    if !credential.isEmpty { values[headerName] = credential }
                    let provider: OpenStreetMapConfiguration? = enabled ? .init(tileURL: tileURL, attribution: attribution,
                        minimumZoom: minimumZoom, maximumZoom: maximumZoom, allowsExport: allowsExport, headers: values) : nil
                    try RemotionMapSettings.save(.init(openStreetMap: provider))
                    message = "Map settings saved. Previews will reload."
                } catch { message = error.localizedDescription }
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .onAppear {
            guard let provider = RemotionMapSettings.configuration.openStreetMap else { return }
            enabled = true; tileURL = provider.tileURL; attribution = provider.attribution
            minimumZoom = provider.minimumZoom; maximumZoom = provider.maximumZoom; allowsExport = provider.allowsExport
            additionalHeaders = provider.headers
            if let key = provider.headers.keys.sorted().first {
                headerName = key; credential = additionalHeaders.removeValue(forKey: key) ?? ""
            }
        }
    }
}
