import KeepoCore
import SwiftUI

/// Capture setup, outside onboarding: for a user who chose "Set up later",
/// changed phones, or deleted the shortcut.
///
/// **The same screens onboarding uses, in a sheet instead of a flow.**
/// `CaptureSetupChecklist` and `CaptureConnectionTestView` are both already
/// independent of their surroundings — the checklist takes a binding, the
/// test carries its own buttons — so this is chrome and a page index, not a
/// second implementation. Anything else would guarantee that the version
/// people reach from Profile is the one that falls behind.
///
/// **Drawn the way onboarding draws it**, so the screens are the same and
/// not merely the same components: the checklist under onboarding's
/// in-content heading rather than a navigation-bar title, and the test with
/// no heading at all, because its content already is one. The bar keeps
/// only the close button.
///
/// **It can open on the pitch.** A caller that sent the user here instead
/// of where they were going — the account form's "add a card" — opens on
/// `CapturePitchScreen` first, so the user sees what capture is and can
/// close the sheet to do it later, rather than landing mid-installation.
/// Profile opens on the checklist, because Profile has already shown the
/// pitch on the screen underneath.
///
/// It closes itself when the test passes, which is the only definition of
/// done this flow has.
struct CaptureSetupFlowView: View {
    let session: SessionStore

    @Environment(\.dismiss) private var dismiss

    private enum Page { case pitch, checklist, test }

    @State private var page: Page
    /// Why the user is looking at capture setup instead of what they tapped,
    /// shown over the pitch's button. Its presence is what opens the flow on
    /// the pitch: someone who came here on purpose needs no reason given.
    private let reason: String?
    /// Deliberately **not** the onboarding key. A user setting capture up
    /// from Profile is not resuming onboarding, and sharing the key would
    /// let one flow arrive with the other's ticks already applied.
    @AppStorage(AppSettingsKeys.captureSetupChecklist) private var completedRaw = ""

    init(session: SessionStore, reason: String? = nil) {
        self.session = session
        self.reason = reason
        _page = State(initialValue: reason == nil ? .checklist : .pitch)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                if page == .pitch {
                    CapturePitchScreen(note: reason) { page = .checklist }
                } else {
                    steps
                }
            }
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

    /// The checklist and the test — onboarding's padding and gap for these
    /// screens (`OnboardingScaffold` with `contentGap: .l`).
    private var steps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                if page == .test {
                    CaptureConnectionTestView(session: session) { dismiss() }
                } else {
                    ScreenHeading(title: "Set up automatic capture")
                    VStack(spacing: AppTheme.Spacing.xl) {
                        CaptureSetupChecklist(completed: completedBinding)
                        // Appears with the finished list rather than sitting
                        // disabled underneath it — same reason as
                        // onboarding's copy of this screen.
                        if isChecklistFinished {
                            PrimaryActionButton(title: "Test Automation", fillsWidth: true) {
                                page = .test
                            }
                        }
                    }
                    .animation(AppTheme.Motion.standard, value: isChecklistFinished)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
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
