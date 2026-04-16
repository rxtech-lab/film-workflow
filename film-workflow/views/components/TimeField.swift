import SwiftUI

struct TimeField: View {
    @Binding var time: TimeInterval
    var placeholder: String = "0:00"

    @State private var text: String = ""

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit())
            .frame(width: 45, height: 20)
            .padding(.horizontal, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .onSubmit {
                if let parsed = SongStructureEntry.parseTime(text) {
                    time = parsed
                }
                text = SongStructureEntry.formatTime(time)
            }
            .onAppear {
                text = SongStructureEntry.formatTime(time)
            }
            .onChange(of: time) { _, newValue in
                text = SongStructureEntry.formatTime(newValue)
            }
    }
}
