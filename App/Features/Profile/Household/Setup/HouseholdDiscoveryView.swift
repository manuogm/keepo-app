import KeepoCore
import SwiftUI

/// The last step before the household exists: two phones finding each other.
///
/// ## Why there is a fallback, and why it appears on a timer
///
/// MultipeerConnectivity has no API that reports whether the user granted the
/// local-network permission. A denial, a phone with Bluetooth off, a corporate
/// Wi-Fi with peer-to-peer blocked and simply nobody being there all present
/// identically: the browser starts and never calls back. There is no error to
/// catch and no state to read.
///
/// So the screen cannot diagnose — it can only notice that nothing has
/// happened for a while and offer the other road. After
/// `fallbackDelay` a QR button appears: the owner shows a code, the guest
/// scans it, and the same one-time token crosses by a different route. The
/// ceremony after it is identical, because the token is all the peer link was
/// ever carrying.
struct HouseholdDiscoveryView: View {
    let session: SessionStore
    let avatars: AvatarStore
    let role: HouseholdPairingIdentity.Role
    let accountIds: [UUID]
    let categoryIds: [UUID]
    var onBuilt: () -> Void

    /// Long enough that a working pairing almost always lands first — a
    /// fallback offered at three seconds teaches the user that the main path
    /// does not work — and short enough that a broken one is not a staring
    /// contest.
    private static let fallbackDelay: Duration = .seconds(12)

    @State var pairing: HouseholdPairingSession?
    @State private var coordinator: HouseholdSetupCoordinator?
    @State private var isShowingFallback = false
    @State private var isShowingQR = false
    @State private var errorMessage: String?
    /// Guest-side only: the digits as typed so far.
    @State var enteredCode = ""
    @FocusState var isCodeFieldFocused: Bool

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            content
        }
        .task { await start() }
        .task {
            try? await Task.sleep(for: Self.fallbackDelay)
            withAnimation(AppTheme.Motion.standard) { isShowingFallback = true }
        }
        .onDisappear { pairing?.stop() }
        .fullScreenCover(isPresented: isCeremonyPresented) {
            if let coordinator {
                HouseholdCeremonyView(
                    session: session, avatars: avatars,
                    coordinator: coordinator, onBuilt: onBuilt
                )
            }
        }
        .sheet(isPresented: $isShowingQR) {
            HouseholdQRView(
                session: session,
                role: role,
                accountIds: accountIds,
                categoryIds: categoryIds,
                onJoined: {
                    isShowingQR = false
                    onBuilt()
                }
            )
        }
        // A burned code is the one failure on this screen the user has to
        // act on rather than just read — the session is over and there is a
        // new code waiting behind the button. The other `.failed` messages
        // stay inline, where they describe a search that is still running.
        .alert("Pairing stopped", isPresented: isAttemptsExhausted) {
            Button("Start Again") { Task { await restart() } }
        } message: {
            Text(HouseholdPairingSession.tooManyAttemptsMessage)
        }
    }

    private var isAttemptsExhausted: Binding<Bool> {
        Binding(
            get: { pairing?.state == .failed(HouseholdPairingSession.tooManyAttemptsMessage) },
            set: { _ in }
        )
    }

    /// Tears the session down and builds a fresh one — which mints a new
    /// code. Deliberately not a "try again" that reuses the old one: the
    /// guesses already spent against it are spent, and handing them back is
    /// the same hole as counting attempts per connection.
    private func restart() async {
        pairing?.stop()
        pairing = nil
        coordinator = nil
        enteredCode = ""
        errorMessage = nil
        await start()
    }

    /// The ceremony takes over the moment a phase actually begins — which for
    /// the owner is the tap on Create Household, and for the guest is the
    /// owner's first announcement arriving.
    private var isCeremonyPresented: Binding<Bool> {
        Binding(get: { coordinator?.hasStarted == true }, set: { _ in })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch pairing?.state {
        case .verifying:
            verifyingView
        case .paired(let peer):
            foundView(peer)
        case .failed(let message):
            searchingView(note: message, isStalled: true)
        case .lost:
            // The peer's own reason when it gave one. The owner burning the
            // attempt budget tears the link down deliberately, and "keep the
            // phones close" would send the guest chasing a radio problem
            // that isn't there.
            searchingView(
                note: pairing?.peerStopReason
                    ?? "The connection dropped. Keep the phones close and Keepo open on both.",
                isStalled: true
            )
        case .searching, .none:
            searchingView(note: nil, isStalled: false)
        }
    }

    // MARK: - Searching

    private func searchingView(note: String?, isStalled: Bool) -> some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()
            RadarPulse(isStalled: isStalled)

            VStack(spacing: AppTheme.Spacing.s) {
                Text("Looking for nearby devices")
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Hold your phones together. Make sure both have Keepo open")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                if let note {
                    Text(note)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AppTheme.Spacing.xs)
                }
            }

            // The owner's code, up while the radios are still looking, so it
            // can be said out loud before the other phone has arrived rather
            // than after.
            if role == .owner {
                codeDisplay
            }

            Spacer()

            if isShowingFallback || isStalled {
                fallback
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fallback: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Text("Taking a while? Instead")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            Button {
                isShowingQR = true
            } label: {
                HStack(spacing: AppTheme.Spacing.s) {
                    Image(systemName: role == .owner ? "qrcode" : "qrcode.viewfinder")
                    Text(role == .owner ? "Show QR Code" : "Scan QR Code")
                }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(PublicSchema.AccountScope.household.tint)
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.m)
                .overlay {
                    Capsule().strokeBorder(
                        PublicSchema.AccountScope.household.tint.opacity(AppTheme.Opacity.fillStrong),
                        lineWidth: 1.5
                    )
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.pressableCard)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Found

    private func foundView(_ peer: HouseholdPairingIdentity) -> some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()
            foundIdentity(peer)

            if let errorMessage {
                FormErrorText(message: errorMessage)
            }

            Spacer()
            foundAction(peer)
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The moment the other person appears is worth a bump — it is the
        // first time either phone confirms the other is really there.
        .sensoryFeedback(AppTheme.Feedback.success, trigger: peer.userId)
    }

    private func foundIdentity(_ peer: HouseholdPairingIdentity) -> some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ProfileAvatarView(
                name: peer.resolvedName,
                // No address on the pairing card — it is not sent over the
                // peer link any more (see `HouseholdPairingIdentity`), and
                // this view only ever wanted one for an initial that
                // `resolvedName` already supplies.
                email: nil,
                // The bytes that came over the peer link. Before a household
                // exists the two users are strangers to the server, so this
                // is the only way there is a real face here at all — see
                // `HouseholdPairingIdentity`.
                image: peer.avatarJPEG.flatMap(UIImage.init(data:)),
                size: AppTheme.Size.illustration
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark")
                    .font(AppTheme.Typography.nanoEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                    .background(AppTheme.Palette.statusPositive, in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
            }

            Text(peer.resolvedName)
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text(role == .owner ? "is ready to join." : "owns this household.")
                .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func foundAction(_ peer: HouseholdPairingIdentity) -> some View {
        if role == .owner {
            Button {
                startCeremony()
            } label: {
                Text("Create Household")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppTheme.Spacing.m)
                    .background(PublicSchema.AccountScope.household.tint, in: Capsule())
            }
            .buttonStyle(.pressableCard)
        } else {
            // The guest has nothing left to decide. Saying who the phone is
            // waiting for is the difference between a screen that is working
            // and a screen that has stopped.
            HStack(spacing: AppTheme.Spacing.s) {
                ProgressView()
                Text("Waiting for \(peer.resolvedName) to start")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }

    // MARK: - Wiring

    private func start() async {
        guard pairing == nil else { return }
        await avatars.load(path: session.profile?.avatarPath, client: session)
        guard let identity = HouseholdPairingSession.identity(
            for: role, session: session, avatar: avatars.image
        ) else {
            errorMessage = "You need to be signed in to build a household."
            return
        }

        let pairing = HouseholdPairingSession(identity: identity)
        let coordinator = HouseholdSetupCoordinator(
            session: session, pairing: pairing, role: role,
            accountIds: accountIds, categoryIds: categoryIds
        )
        self.pairing = pairing
        self.coordinator = coordinator
        pairing.start()

        // The guest's coordinator runs from the moment the link is up: its
        // first act is to wait for the owner's token, so it has to already be
        // listening when the owner presses the button. The owner's waits for
        // that press.
        if role == .guest {
            Task { await coordinator.run() }
        }
    }

    private func startCeremony() {
        guard let coordinator else { return }
        Task { await coordinator.run() }
    }
}

// MARK: - The searching animation

/// Three rings breathing outward from the household glyph.
///
/// It stops when the search has stalled, and that is the whole point of the
/// `isStalled` flag: an animation that keeps going while the screen says
/// something has gone wrong reads as a screen that has not noticed.
private struct RadarPulse: View {
    let isStalled: Bool

    @State private var isAnimating = false

    private var tint: Color { PublicSchema.AccountScope.household.tint }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(tint.opacity(AppTheme.Opacity.fillStrong), lineWidth: 1.5)
                    .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                    .scaleEffect(isAnimating && !isStalled ? 2.4 : 1)
                    .opacity(isAnimating && !isStalled ? 0 : 1)
                    .animation(
                        isStalled
                            ? .default
                            : .easeOut(duration: 2.4).repeatForever(autoreverses: false)
                                .delay(Double(ring) * 0.8),
                        value: isAnimating
                    )
            }

            KeepoIcon(name: "icon-home-filled", size: AppTheme.Size.icon)
                .foregroundStyle(tint)
                .frame(width: AppTheme.Size.illustration, height: AppTheme.Size.illustration)
                .background(tint.opacity(AppTheme.Opacity.fill), in: Circle())
        }
        .frame(height: AppTheme.Size.illustration * 2.4)
        .onAppear { isAnimating = true }
        .accessibilityHidden(true)
    }
}
