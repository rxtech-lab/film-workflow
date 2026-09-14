import FilmTemplateKit
import RxAgentSDK
import SwiftUI

/// What a Simple mode step looks like in the agent transcript.
///
/// The page itself lives in the wizard window, so a raw tool card here would
/// show a wall of json-render JSON. This says what was asked instead, which is
/// what someone reading the thread afterwards actually wants to know.
struct WizardStepCard: View {
    struct Summary {
        let symbol: String
        let title: String
        let chips: [String]
    }

    let summary: Summary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: summary.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.title)
                    .font(.system(size: 12, weight: .medium))
                if !summary.chips.isEmpty {
                    FlowChips(labels: summary.chips)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.16))
        }
        .accessibilityIdentifier("agent.wizard-step")
    }

    /// Reads the card out of the call's *arguments*: the result is a sentence
    /// telling the model to stop, while the arguments are the page.
    static func summary(for call: AgentToolCall) -> Summary? {
        let name = MCPToolName.bare(call.name)
        guard WizardTool.isWizardTool(name), call.hasCompleteInput else { return nil }

        switch name {
        case WizardTool.presentTemplates:
            let candidates = call.input["candidates"]?.arrayValue ?? []
            let titles = candidates.compactMap { $0.objectValue?["item_id"]?.stringValue }
            return Summary(
                symbol: "rectangle.stack",
                title: "Suggested \(candidates.count) template\(candidates.count == 1 ? "" : "s")",
                chips: Array(titles.prefix(5))
            )
        case WizardTool.presentOptions:
            let title = call.input["title"]?.stringValue
            return Summary(
                symbol: "slider.horizontal.3",
                title: title.map { "Asked: \($0)" } ?? "Asked the user to choose how it looks",
                chips: []
            )
        case WizardTool.reportProgress:
            guard let message = call.input["message"]?.stringValue, !message.isEmpty else { return nil }
            return Summary(symbol: "hourglass", title: message, chips: [])
        default:
            return nil
        }
    }
}

/// Short labels, wrapped.
private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    private var chips: some View {
        ForEach(labels, id: \.self) { label in
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }
}
