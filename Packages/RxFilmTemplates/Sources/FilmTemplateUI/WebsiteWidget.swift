import FilmTemplateKit
import Foundation
import JSONSchema
import JSONSchemaForm
import SwiftUI

enum WebsiteWidget {
    static let name = IntakeFormDefinition.websiteWidget

    static let widget: JSONSchemaFormWidget = { context in
        AnyView(WebsiteField(
            title: context.schema.title ?? "Company website",
            detail: context.schema.description,
            placeholder: context.uiSchema?["ui:placeholder"] as? String ?? "https://example.com",
            website: Binding(
                get: { context.formData.wrappedValue.string ?? "" },
                set: { context.formData.wrappedValue = .string($0) }
            )
        ))
    }
}

private struct WebsiteField: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var website: String
    @Environment(\.openURL) private var openURL

    @State private var checkedText: String?
    @State private var status: Status = .idle
    @State private var retryCount = 0

    private enum Status {
        case idle
        case checking
        case reachable(URL)
        case unavailable(String)
    }

    private struct CheckID: Equatable {
        let text: String
        let retry: Int
    }

    // A completed check belongs only to its original text. Editing must hide
    // its checkmark and link immediately, even before the new task starts.
    private var visibleStatus: Status {
        if website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .idle }
        return checkedText == website ? status : .checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(title, text: $website, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("intake.website")

            statusRow
                .font(.caption)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .task(id: CheckID(text: website, retry: retryCount)) {
            await check(website)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch visibleStatus {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking website…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("intake.website.checking")
        case .reachable(let url):
            HStack(spacing: 12) {
                Label("Website is reachable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("intake.website.reachable")
                Spacer(minLength: 0)
                Button {
                    openURL(url)
                } label: {
                    Label("Open website", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open \(url.absoluteString) in your browser to confirm this is the right company.")
                .accessibilityIdentifier("intake.website.open")
            }
        case .unavailable(let message):
            HStack(spacing: 12) {
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("intake.website.unavailable")
                Spacer(minLength: 0)
                if IntakeSubmission.normalizedURL(website) != nil {
                    Button("Try again") {
                        status = .checking
                        retryCount += 1
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("intake.website.retry")
                }
            }
        }
    }

    private func check(_ text: String) async {
        checkedText = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .idle
            return
        }
        guard let url = IntakeSubmission.normalizedURL(text) else {
            status = .unavailable("Enter a valid website address.")
            return
        }
        status = .checking
        do {
            try await Task.sleep(for: .milliseconds(500))
            let reachable = try await WebsiteReachability.check(url)
            try Task.checkCancellation()
            guard website == text else { return }
            status = reachable ? .reachable(url) : .unavailable("Website is unavailable.")
        } catch {
            guard !Task.isCancelled, website == text else { return }
            status = .unavailable("Couldn’t reach website. Check the address or try again.")
        }
    }
}
