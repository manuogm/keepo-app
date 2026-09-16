import KeepoCore
import SwiftUI
import UIKit

/// Step 4c — a real cross-process round trip, and a claim that is exactly
/// as strong as what it proves.
///
/// Keepo runs the published shortcut through Shortcuts' `x-callback-url`
/// API with no input. The shortcut's own header says *"If there's no
/// input: Continue"*, so `CaptureIntent` is reached with all three fields
/// empty and — only inside the window `CaptureTestSession` opens seconds
/// earlier — writes a local-only test capture. Nothing is simulated
/// in-process; the capture really is written by the Shortcuts host, which
/// is why it proves what it proves.
///
/// **What this verifies:** the shortcut exists under the expected name, it
/// contains Keepo's action, the intent is registered and invocable across
/// processes, the Shortcuts host can read the Keychain session (a wrong
/// client here was once the root cause of every capture failing outright),
/// the write lands, and the notification fires with its quick actions.
///
/// **What it cannot verify, ever:** that the Wallet automation exists at
/// all, which cards it is bound to, and whether "Run Immediately" is set.
/// iOS exposes no API to enumerate or inspect a personal automation. So the
/// copy says both halves, and the second half is settled later by
/// `AppSettings.captureVerifiedAt` when a real purchase arrives.
struct SetupCaptureTestSubStep: View {
    let session: SessionStore
    let store: OnboardingDraftStore
    let onNext: () -> Void
    let onBack: () -> Void

    private enum Phase: Equatable {
        case idle
        case waiting
        case arrived(TestCaptureQueries.TestCapture)
        case failed(String)

        /// Nothing to press while the test is about to run or running. The
        /// bar comes back for the two outcomes that need an answer.
        var showsForwardButton: Bool {
            switch self {
            case .idle, .waiting: return false
            case .arrived, .failed: return true
            }
        }
    }

    /// Ten seconds. The round trip is a couple of seconds when it works;
    /// past this it is not slow, it is not coming.
    private static let timeout = Duration.seconds(10)
    private static let poll = Duration.milliseconds(400)
    /// Long enough to read one sentence before the screen hands itself over
    /// to Shortcuts, short enough that it never reads as the app having
    /// stalled.
    private static let readingDelay = Duration.milliseconds(1800)

    @State private var phase: Phase = .idle
    @State private var isDeleting = false

    var body: some View {
        OnboardingScaffold(
            title: "Let's check it works",
            step: .capture,
            onBack: onBack,
            // **No Skip, and no subtitle.** The escape was here twice over
            // — once in the chrome and once as the bottom-right button,
            // which put "Skip the test" in the accent fill beside the real
            // action. Both are gone: the way out of capture setup is the
            // intro's "Set up later", which Back reaches in two taps, and a
            // user who has already installed the shortcut is one tap from
            // finding out whether it works. An escape offered at this point
            // mostly produces half-built automations.
            primaryTitle: primaryTitle,
            isPrimaryEnabled: isPrimaryEnabled,
            // Nothing to press while the test is running itself. See
            // `idleBlock`.
            isPrimaryVisible: phase.showsForwardButton,
            onPrimary: runPrimary
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                switch phase {
                case .idle: idleBlock
                case .waiting: waitingRow
                case .arrived(let capture): arrivedBlock(capture)
                case .failed(let message): failedBlock(message)
                }
            }
            // Fires once, on the way in. Keyed on nothing, so coming *back*
            // to a completed test does not silently re-run it — `.task`
            // re-runs on reappearance and the guard is what makes this a
            // one-shot rather than a loop the Back button can restart.
            .task {
                guard phase == .idle, CaptureTestSession.canRunShortcuts else { return }
                try? await Task.sleep(for: Self.readingDelay)
                guard phase == .idle else { return }
                await runTest()
            }
        }
    }

    private var primaryTitle: String {
        switch phase {
        case .idle: return "Test it now"
        case .waiting: return "Testing…"
        case .arrived: return "Next"
        case .failed: return "Try again"
        }
    }

    private var isPrimaryEnabled: Bool {
        guard phase != .waiting else { return false }
        // Shortcuts can be deleted from a device. A button that opens
        // nothing is worse than a button that is visibly not available.
        if case .idle = phase { return CaptureTestSession.canRunShortcuts }
        return true
    }

    private func runPrimary() {
        switch phase {
        case .idle, .failed:
            Task { await runTest() }
        case .arrived:
            onNext()
        case .waiting:
            break
        }
    }

    // MARK: - Idle

    /// **No button at all — the screen runs the test itself.**
    ///
    /// There was nothing else to do here. The user had just been told the
    /// app was about to check the shortcut, and the only thing standing
    /// between them and that was a tap on a button that said so a second
    /// time. Removing it takes the last piece of ceremony out of the
    /// longest step in setup; the short delay before it fires is there so
    /// the sentence can be read before the screen starts changing.
    ///
    /// The one case that still needs words is the one where the test cannot
    /// run at all, because a screen that silently does nothing is the thing
    /// prose is actually for.
    @ViewBuilder
    private var idleBlock: some View {
        if CaptureTestSession.canRunShortcuts {
            Text("Testing the connection with your shortcut…")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        } else {
            Text("The Shortcuts app isn't installed, so there's nothing to test against. "
                 + "Install it from the App Store and you can run this from Profile → My Automations.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The same sentence as `idleBlock`, with the spinner that says it has
    /// actually started. Keeping the wording identical means the screen does
    /// not appear to change its mind about what it is doing the moment the
    /// test fires.
    private var waitingRow: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("Testing the connection with your shortcut…")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Arrived

    private func arrivedBlock(_ capture: TestCaptureQueries.TestCapture) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            Label("It works", systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.statusPositive)

            TestCaptureCard(capture: capture)

            // Delete is the primary action and the test capture is **never**
            // auto-deleted — the user made it, so the user removes it. The
            // same affordance lives in Profile → My Automations for as long
            // as one exists, so backgrounding the app here cannot strand a
            // fake purchase with nothing left pointing at it.
            OnboardingPrimaryButton(title: "Delete the test purchase", isLoading: isDeleting, fillsWidth: true) {
                Task { await deleteTestCapture() }
            }
            Text("Or keep it and delete it later from Profile → My Automations.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    // MARK: - Failed

    private func failedBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            Label("That didn't come back", systemImage: "exclamationmark.triangle")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.statusNegative)

            // Shortcuts' own wording, verbatim. It names the real problem —
            // "the shortcut Keepo Capture was not found", an action that
            // failed — and any paraphrase of ours would be a guess at which
            // of those it was.
            Text(message)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The commonest cause is the shortcut being named something else. Importing it twice "
                 + "leaves the second copy called “\(ShortcutsWalkthrough.shortcutName) 1”.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    // MARK: - The round trip

    private func runTest() async {
        guard let url = CaptureTestSession.runShortcutURL else { return }
        CaptureTestCoordinator.shared.clear()
        // Cleared first so a second run cannot pass on the row the first
        // one left behind.
        try? await session.dbQueue.write { try TestCaptureQueries.delete($0) }
        CaptureTestSession.open()
        phase = .waiting
        await UIApplication.shared.open(url)
        await awaitCapture()
    }

    /// **The pass condition is the capture arriving, never `x-success`.**
    /// That callback only says the shortcut finished — a shortcut can run
    /// and write nothing, which is exactly what happens when an import
    /// collided and this ran an older copy. So this watches the local
    /// mirror for the row itself, and treats `x-error` and the timeout as
    /// the two ways to fail.
    ///
    /// Polled rather than driven by the `CaptureNotify` Darwin
    /// notification: polling checks the actual condition rather than a
    /// signal that the condition *might* now hold, and a 400ms local SQLite
    /// read for at most ten seconds is not a cost worth optimising against
    /// correctness.
    private func awaitCapture() async {
        let deadline = ContinuousClock.now + Self.timeout
        while ContinuousClock.now < deadline {
            if let error = CaptureTestCoordinator.shared.shortcutError {
                CaptureTestSession.close()
                phase = .failed(error)
                return
            }
            let found = try? await session.dbQueue.read { try TestCaptureQueries.fetch($0) }
            if let capture = found ?? nil {
                CaptureTestSession.close()
                // Every screen that counts transactions reads through the
                // refresh token, so the row has to be announced even though
                // it is deliberately absent from Needs Review.
                session.refresh.bump()
                phase = .arrived(capture)
                return
            }
            try? await Task.sleep(for: Self.poll)
            if Task.isCancelled { return }
        }
        CaptureTestSession.close()
        phase = .failed(
            "Shortcuts didn't send anything back within ten seconds. Check that the shortcut is called "
                + "“\(ShortcutsWalkthrough.shortcutName)” and try again."
        )
    }

    private func deleteTestCapture() async {
        isDeleting = true
        try? await session.dbQueue.write { try TestCaptureQueries.delete($0) }
        session.refresh.bump()
        isDeleting = false
        onNext()
    }
}

/// The captured test purchase, drawn the way the app draws a transaction —
/// because what it is demonstrating is that a real row was written, and a
/// bespoke "success" panel would demonstrate nothing.
struct TestCaptureCard: View {
    let capture: TestCaptureQueries.TestCapture

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(capture.merchant)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(capture.accountName.map { "\(capture.categoryName) · \($0)" } ?? capture.categoryName)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Text(MoneyFormatter.format(
                capture.amountE4,
                currency: CurrencyInfo(code: capture.currency ?? "USD", minorUnit: capture.minorUnit)
            ))
            .font(AppTheme.Typography.bodyEmphasis)
            .monospacedDigit()
            .foregroundStyle(AppTheme.Palette.textPrimary)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .combine)
    }
}
