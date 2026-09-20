import KeepoCore
import SwiftUI

/// Capture setup, outside onboarding: for a user who chose "Set up later",
/// changed phones, or deleted the shortcut.
///
/// **The same two screens onboarding uses, in a sheet instead of a flow.**
/// `CaptureSetupChecklist` and `CaptureConnectionTestView` are both already
/// independent of their surroundings — the checklist takes a binding, the
/// test carries its own buttons — so this is chrome and a page index, not a
/// second implementation. Anything else would guarantee that the version
/// people reach from Profile is the one that falls behind.
///
/// It closes itself when the test passes, which is the only definition of
/// done this flow has.
struct CaptureSetupFlowView: View {
    let session: SessionStore

    @Environment(\.dismiss) private var dismiss

    private enum Page { case checklist, test }

    @State private var page: Page = .checklist
    /// Deliberately **not** the onboarding key. A user setting capture up
    /// from Profile is not resuming onboarding, and sharing the key would
    /// let one flow arrive with the other's ticks already applied.
    @AppStorage(AppSettingsKeys.captureSetupChecklist) private var completedRaw = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        switch page {
                        case .checklist:
                            CaptureSetupChecklist(completed: completedBinding)
                            // Appears with the finished list rather than
                            // sitting disabled underneath it — same reason
                            // as onboarding's copy of this screen.
                            if isChecklistFinished {
                                PrimaryActionButton(title: "Test Automation", fillsWidth: true) {
                                    page = .test
                                }
                            }
                        case .test:
                            CaptureConnectionTestView(session: session) { dismiss() }
                        }
                    }
                    .padding(AppTheme.Spacing.l)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle(page == .checklist ? "Set up automatic capture" : "Let's check it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .interactiveDismissDisabled(page == .test)
    }

    private var completed: Set<Int> {
        Set(completedRaw.split(separator: ",").compactMap { Int($0) })
    }

    private var isChecklistFinished: Bool {
        ShortcutsWalkthrough.steps.allSatisfy { completed.contains($0.id) }
    }

    private var completedBinding: Binding<Set<Int>> {
        Binding(
            get: { completed },
            set: { completedRaw = $0.sorted().map(String.init).joined(separator: ",") }
        )
    }
}
