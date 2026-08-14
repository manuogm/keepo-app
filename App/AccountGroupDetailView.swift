import SwiftUI

/// Destination for the Everyday/Investments aggregate row on
/// `AccountsListView` — content to come in a later pass.
struct AccountGroupDetailView: View {
    let title: String

    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
