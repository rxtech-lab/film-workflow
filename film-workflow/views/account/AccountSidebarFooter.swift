import SwiftUI

extension View {
    func accountSidebarFooter() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                AccountControl(placement: .sidebarFooter)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }
}
