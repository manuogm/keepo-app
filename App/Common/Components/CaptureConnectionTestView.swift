import KeepoCore
import SwiftUI
import UIKit
import os

/// A real cross-process round trip through Shortcuts, and a claim that is
/// exactly as strong as what it proves.
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
///
/// **It carries its own buttons**, which is what makes it portable. This
/// began as onboarding's step 4c, with its actions in the scaffold's bottom
/// bar; Profile → My Automations needs the identical test with no scaffold
/// around it, and a version whose forward action lived in its host would
/// have had to be written twice. Nothing here knows where it is.
struct CaptureConnectionTestView: View {
    let session: SessionStore
    /// Called when the user is finished with the result — after deleting
    /// the test purchase, or after choosing to keep it.
    let onFinished: () -> Void

    private enum Phase: Equatable {
        case idle
        case waiting
        case arrived(TestCaptureQueries.TestCapture)
        case failed(String)
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
    /// Flipped a beat after the capture lands, and it drives all three
    /// parts of the celebration at once — the mark's pop, the burst and the
    /// haptic. One trigger rather than three keeps them in step; the haptic
    /// landing a frame before the confetti is the difference between a
    /// celebration and a glitch. Same shape as `SetupAllSetView`.
    @State private var hasLanded = false
    @State private var isAskingAboutTestPurchase = false
    @State private var decision: TestPurchaseDecision?
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    /// Keep or delete, and `nil` until the user says. A swipe down without
    /// answering counts as Keep: nothing is destroyed, the flow moves on,
    /// and the same offer stays in Profile → My Automations for as long as
    /// a test purchase exists.
    enum TestPurchaseDecision {
        case keep
        case delete
    }

    /// A breath before the burst fires. The block appears while the waiting
    /// spinner is still on its way out, and a burst that starts during that
    /// transition is a burst nobody sees the start of.
    private static let celebrationDelay = Duration.milliseconds(250)
    /// How long the celebration has to itself before the sheet asks its
    /// question. Long enough to watch the confetti land, short enough that
    /// it never reads as the app waiting for something.
    private static let questionDelay = Duration.milliseconds(2000)

    /// Shortcuts' own message no longer reaches the screen, so it has to
    /// reach somewhere — a failure nobody can reproduce is one nobody can
    /// diagnose.
    private let logger = Logger(subsystem: "app.keepo", category: "CaptureTest")

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            switch phase {
            case .idle: idleBlock
            case .waiting: waitingRow
            case .arrived(let capture): arrivedBlock(capture)
            case .failed(let message): failedBlock(message)
            }
        }
        // Fires once, on the way in. The guard is what makes this a one-shot
        // rather than a loop: `.task` re-runs on reappearance, and coming
        // back to a completed test must not silently re-run it.
        .task {
            guard phase == .idle, CaptureTestSession.canRunShortcuts else { return }
            try? await Task.sleep(for: Self.readingDelay)
            guard phase == .idle else { return }
            await runTest()
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

    /// **The payoff, and then the question — never both at once.** Delete
    /// and Keep used to sit under the tile on this screen, which meant the
    /// moment capture started working was also the moment the user was
    /// asked to tidy up after it. The celebration gets the screen to itself
    /// and the housekeeping arrives in a sheet once it is over.
    private func arrivedBlock(_ capture: TestCaptureQueries.TestCapture) -> some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.Size.illustration * typeScale))
                .foregroundStyle(AppTheme.Palette.statusPositive)
                // Lands rather than appears. The spring overshoots slightly,
                // which is what makes it read as a stamp coming down instead
                // of an image fading in.
                .scaleEffect(hasLanded ? 1 : 0.5)
                .opacity(hasLanded ? 1 : 0)
                .animation(AppTheme.Motion.standard, value: hasLanded)

            VStack(spacing: AppTheme.Spacing.s) {
                Text("You made it!")
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                // A step down, because it is the same sentence finishing.
                // Kept short enough to hold one line on a phone — the point
                // of the pair is that it reads at a glance.
                Text("Auto capturing is ready to go")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        // **Behind the mark and bigger than the block it decorates.** The
        // pieces start where the checkmark is and have to be free to travel;
        // sized to this stack alone they would stop in a rectangle around
        // the words. The scroll view still clips them at its own bounds,
        // which is most of the screen and the most this view can reach
        // without knowing where it is drawn.
        .background {
            ConfettiBurst(isActive: hasLanded)
                .frame(width: AppTheme.Size.illustration * 12, height: AppTheme.Size.illustration * 12)
                .allowsHitTesting(false)
        }
        // Fires whether or not the confetti does: Reduce Motion suppresses
        // the pieces, and a success the user cannot see is exactly when the
        // one they can feel matters most.
        .sensoryFeedback(AppTheme.Feedback.success, trigger: hasLanded)
        .task {
            try? await Task.sleep(for: Self.celebrationDelay)
            hasLanded = true
            try? await Task.sleep(for: Self.questionDelay)
            isAskingAboutTestPurchase = true
        }
        .sheet(isPresented: $isAskingAboutTestPurchase, onDismiss: act) {
            TestPurchaseDecisionSheet(
                capture: capture,
                baseCurrency: session.profile?.baseCurrency,
                onDecide: { decision = $0 }
            )
        }
    }

    /// Runs after the sheet is gone rather than from inside it: `onFinished`
    /// tears this view down, and doing that while a sheet is still on screen
    /// leaves the sheet without a presenter.
    private func act() {
        switch decision ?? .keep {
        case .keep:
            onFinished()
        case .delete:
            Task { await deleteTestCapture() }
        }
    }

    // MARK: - Failed

    /// **One cause, named.** This used to print Shortcuts' own error
    /// verbatim and then explain the likeliest reason underneath it — two
    /// blocks of prose, one of them written by another app, in front of
    /// somebody who wanted to know what to fix. Nearly every failure here is
    /// the same thing: the automation points at a shortcut whose name is not
    /// the one Keepo runs, usually because importing it twice left a copy
    /// called "Keepo Capture 1". So the screen says that, and offers the two
    /// things that act on it.
    ///
    /// The underlying message is not lost — it still reaches the console
    /// through the phase — it is just no longer the first thing a user reads
    /// when something breaks.
    private func failedBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            Text("Upss, that didn't work…")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.statusNegative)
                .fixedSize(horizontal: false, vertical: true)

            Text("The shortcut wasn't found. Make sure the name of the shortcut inside your automation "
                 + "is: \(ShortcutsWalkthrough.shortcutName)")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingPrimaryButton(title: "Try again", fillsWidth: true) {
                Task { await runTest() }
            }

            // Under the retry, because it is the thing you do *before*
            // retrying — the name has to be fixed in Shortcuts first, and
            // the fix is two taps away in an app the user has to leave for
            // anyway.
            Button {
                openShortcuts()
            } label: {
                Text("Open Shortcuts")
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: AppTheme.Size.touchTarget)
                    .overlay(Capsule().stroke(AppTheme.Palette.textSecondary, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Shortcuts app so you can check the name")
        }
        .onAppear { logger.error("Capture test failed: \(message, privacy: .public)") }
    }

    private func openShortcuts() {
        guard let url = URL(string: "shortcuts://"), UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
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
                // Recorded here rather than on the way out: the round trip
                // completing is the thing that proves the setup, and a user
                // who backgrounds the app on this screen has still done it.
                AppSettings.markCaptureSetupCompleted()
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
        try? await session.dbQueue.write { try TestCaptureQueries.delete($0) }
        session.refresh.bump()
        onFinished()
    }
}
