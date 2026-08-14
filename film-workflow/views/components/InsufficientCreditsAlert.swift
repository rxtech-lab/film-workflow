import SwiftUI

struct InsufficientCreditsNotice: Identifiable {
    let id = UUID()
    let available: Int
    let required: Int
    let creditsURL: URL?

    init?(_ error: Error) {
        guard let backend = error as? BackendError,
              case let .insufficientCredits(available, required, creditsURL) = backend
        else { return nil }
        self.available = available
        self.required = required
        self.creditsURL = creditsURL
    }
}

extension View {
    func insufficientCreditsAlert(_ notice: Binding<InsufficientCreditsNotice?>) -> some View {
        alert(item: notice) { value in
            #if os(macOS)
            Alert(
                title: Text("Not enough credits"),
                message: Text("You need \(value.required.formatted()) credits; \(value.available.formatted()) are available."),
                primaryButton: .default(Text("Top Up")) {
                    CreditBalanceStore.shared.openTopUp()
                },
                secondaryButton: .cancel()
            )
            #else
            Alert(
                title: Text("Not enough credits"),
                message: Text("You need \(value.required.formatted()) credits; \(value.available.formatted()) are available."),
                dismissButton: .cancel()
            )
            #endif
        }
    }
}
