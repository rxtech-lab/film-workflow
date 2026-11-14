import MotionCore
import SwiftUI

/// Settings › Remotion: native render tuning and map services for compositions.
struct RemotionSettingsView: View {
    @AppStorage(RemotionRenderPreferences.concurrencyKey) private var concurrency = 0
    @AppStorage(MapServices.mapboxTokenDefaultsKey) private var mapboxToken = ""

    var body: some View {
        Form {
            Section("Rendering") {
                Picker("Frames at a time", selection: $concurrency) {
                    Text("Automatic").tag(0)
                    ForEach(1...4, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .accessibilityIdentifier("settings.remotion.concurrency")
                Text("Compositions render natively with Skia and Metal. Render more frames at once for faster exports; higher settings use more memory. Changes apply to the next render.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Maps") {
                Text("Compositions can draw OpenStreetMap and Apple Maps with @motionswift/map.")
                SecureField("Mapbox access token (optional)", text: $mapboxToken)
                    .accessibilityIdentifier("settings.remotion.mapboxToken")
                Text("Needed only for Mapbox map styles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
