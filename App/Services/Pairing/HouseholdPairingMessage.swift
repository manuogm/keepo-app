import Foundation

/// Everything two phones say to each other while a household is being built.
///
/// ## What deliberately is not in here
///
/// No balance, no transaction, no account id, no category. **The peer link
/// carries a handshake, never the ledger.** Every account, category and tag
/// that ends up shared crosses through `accept_invite` on the server, under
/// the RLS policies that are the entire access model — a phone handing
/// another phone its money data directly would put that data outside every
/// guarantee the schema makes about who may read what.
///
/// So this protocol carries exactly four things: a six-digit code proof and
/// its answer, who you are (so the other phone can draw your face before a
/// household exists and RLS would rightly refuse), one single-use invite
/// token, and where each side has got to in the ceremony. The animation is a
/// narration of real server work, and this is the wire it is narrated over.
///
/// ## The code comes first, and that ordering is the security property
///
/// Identity is not sent when the link opens. It is sent when the code has
/// been accepted, and not before. The distinction is the whole of security
/// audit finding 6: gating only the *token* would still leave a name and a
/// face readable by anything in Bluetooth range that connects, which was the
/// original defect. The order on the wire is:
///
///     connect → codeProof → codeAccepted → identity (both ways) → invite
///
/// A wrong code never reaches the second arrow, so it never learns who is
/// holding the other phone.
///
/// ## On versioning
///
/// `protocolVersion` rides on the identity message and both sides check it
/// before going further. Two phones on different app versions meeting at a
/// kitchen table is not an edge case, it is the normal way an update rolls
/// out across a household, and the failure to design for has a shape: one
/// side sits at "Looking for nearby devices" forever while the other shows a
/// face. Better to say so.
enum HouseholdPairingMessage: Codable, Hashable, Sendable {
    /// Guest → owner. The six digits the owner read out, as typed.
    ///
    /// Sent over the `MCSession`, which is encrypted (`.required`), and sent
    /// in the clear rather than hashed — deliberately. A hash of a six-digit
    /// code is brute-forced offline in the time it takes to write the loop,
    /// so hashing here would buy nothing while suggesting it had.
    case codeProof(code: String)
    /// Owner → guest. The digits were right; identities may now cross.
    case codeAccepted
    /// Owner → guest. They were not. `attemptsRemaining` is what the guest
    /// puts on screen, because "wrong code" with no count is a screen that
    /// gives no warning before the session is abandoned.
    case codeRejected(attemptsRemaining: Int)
    /// Sent by both sides once, and **only once the code has been accepted**
    /// — never on connect. See `HouseholdPairingIdentity`.
    case identity(HouseholdPairingIdentity)
    /// Owner → guest. The one-time token minted by `create_invite`, which the
    /// guest immediately spends on `accept_invite`.
    case invite(token: String)
    /// Guest → owner. `accept_invite` returned; every share both sides chose
    /// is now real on the server.
    case joined
    /// Owner → guest. Which step of the ceremony to draw. The owner is the
    /// single source of truth for the narration so the two phones can never
    /// tell the user different stories.
    case phase(HouseholdCeremonyPhase)
    /// Owner → guest. The report is finished and the household is real —
    /// fill the house the rest of the way.
    case finished
    /// Either side. The other user backed out; go back to discovery rather
    /// than waiting on a peer that has stopped listening.
    case cancelled(reason: String?)
}

/// Who is holding the other phone, as much as is needed to draw them.
///
/// The avatar travels as JPEG bytes rather than as a storage path, and that
/// is not an optimisation. Before the household exists the two users are
/// strangers to the server: `avatars_select` scopes the bucket to your own
/// folder, so the owner genuinely cannot fetch the guest's picture until
/// they are members together. The bytes are how the discovery card can show
/// a real face at the one moment it matters most — deciding whether the
/// person the phone found is the person sitting opposite.
///
/// Capped hard at 24 KB. `MCSession` will carry far more, but this is sent
/// over Bluetooth in the worst case and a slow identity exchange is a
/// discovery screen that looks broken.
/// ## What is deliberately not on this card either
///
/// **No email address.** It used to be here, as a fallback for the name, and
/// the security audit of 2026-09-21 (finding 6) established what that cost:
/// the owner advertises while sitting on the discovery screen, the advertiser
/// accepts every invitation that arrives without asking, and both sides send
/// this struct the instant the link opens — all before any human has
/// confirmed anything. Anything in here is therefore readable by any device
/// within Bluetooth range that speaks the protocol, with no interaction on
/// the victim's phone at all.
///
/// A name and a face have to be here: recognising the person opposite is the
/// entire job of the discovery card, and there is no way to do that job
/// without showing them. An email address does not help with it — the card
/// draws the face and the chosen name, and `ProfileAvatarView` only ever
/// used the address for an initial it can take from the name instead.
///
/// Nothing downstream is affected: once the household exists, the peer's
/// address comes from `household_member_profile()` on the server, under RLS,
/// which is where `HouseholdView` and the report already read it from.
struct HouseholdPairingIdentity: Codable, Hashable, Sendable {
    /// Bumped to 2 when `email` was removed (20261004, audit finding 6).
    ///
    /// Decoding would have survived without a bump — an old phone's extra
    /// key is ignored, a new phone's absent one lands in an `Optional` — and
    /// that is exactly the problem. Left compatible, a new phone would still
    /// receive, and an old phone would still send, the address this change
    /// exists to stop putting on the air. Refusing the pair is the only way
    /// the fix binds both ends, and the mismatch already has an honest
    /// message telling both people to update.
    static let protocolVersion = 2
    static let maxAvatarBytes = 24_000

    var protocolVersion: Int = HouseholdPairingIdentity.protocolVersion
    /// The user's own id. Checked against the invite on the owner's side so a
    /// phone cannot pair with itself across two simulators signed into one
    /// account — which is exactly how this gets tested, and would otherwise
    /// fail deep inside `accept_invite` with "cannot accept your own invite".
    let userId: UUID
    let displayName: String?
    let role: Role
    /// JPEG, already downscaled. Nil when the user has no avatar, which is
    /// the common case — the card falls back to the initial, exactly as every
    /// other avatar in the app does.
    let avatarJPEG: Data?

    enum Role: String, Codable, Hashable, Sendable {
        /// Creating the household, and holding setup authority over it.
        case owner
        /// Joining one.
        case guest
    }

    /// The name to draw, never blank: the chosen name, then a word rather
    /// than an empty label.
    ///
    /// The address used to sit between the two. Onboarding requires a display
    /// name (`SetupAllSetView` will not let the step complete without one),
    /// so in practice the fallback was already unreachable — which is part of
    /// why sending the address to every device in range bought so little.
    var resolvedName: String {
        guard let name = displayName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return "Keepo user" }
        return name
    }
}

/// The ten steps of the ceremony, in the order they are narrated.
///
/// The order is the user-facing story; the work behind it is
/// `HouseholdSetupCoordinator`'s business. Several steps sit in front of the
/// same server call — `accept_invite` applies both members' accounts and both
/// members' categories in one transaction — and that is fine and honest: the
/// phases still only advance once the work behind them has actually
/// returned. What they must never do is run ahead of it.
enum HouseholdCeremonyPhase: Int, Codable, CaseIterable, Hashable, Sendable {
    case sharingProfiles
    case sharingAccounts
    case receivingAccounts
    case sharingCategories
    case receivingCategories
    case mergingCategories
    case sharingTags
    case receivingTags
    case mergingTags
    case buildingHousehold

    var title: String {
        switch self {
        case .sharingProfiles: return "Sharing Profiles"
        case .sharingAccounts: return "Sharing Accounts"
        case .receivingAccounts: return "Receiving Accounts"
        case .sharingCategories: return "Sharing Categories"
        case .receivingCategories: return "Receiving Categories"
        case .mergingCategories: return "Merging Categories"
        case .sharingTags: return "Sharing Tags"
        case .receivingTags: return "Receiving Tags"
        case .mergingTags: return "Merging Tags"
        case .buildingHousehold: return "Building Household"
        }
    }

    /// Which way the data is moving, which is what the travelling particles
    /// in the ceremony draw. A merge is neither — it happens on one side, so
    /// nothing crosses the gap and the animation says so by going still.
    enum Direction {
        case outbound
        case inbound
        case local
    }

    var direction: Direction {
        switch self {
        case .sharingProfiles, .sharingAccounts, .sharingCategories, .sharingTags:
            return .outbound
        case .receivingAccounts, .receivingCategories, .receivingTags:
            return .inbound
        case .mergingCategories, .mergingTags, .buildingHousehold:
            return .local
        }
    }

    /// How full the house is once this step is done, as a percentage.
    ///
    /// Written out rather than computed, and deliberately not a pattern. Ten
    /// equal ninths made the six steps that narrate something an earlier gate
    /// already made true feel as slow as the three with a server round trip
    /// behind them. But a *tidy* weighting is its own tell — a ladder of
    /// 5, 10, 25, 30, 35 is visibly arithmetic, and progress that can be
    /// predicted a step ahead stops being read as progress and starts being
    /// read as an animation.
    ///
    /// So these are hand-set: uneven, unrounded, no repeating interval, and
    /// **no two consecutive steps the same size**, which is the property that
    /// makes a ladder look counted rather than authored. The three long jumps
    /// are the three real gates — `accept_invite` returning, the fuzzy pass
    /// with its merge RPC and two pulls, and the final sync.
    ///
    /// It stops at 90, not 100. The house is deliberately left unfinished
    /// while the owner reviews the report and the guest waits — the household
    /// is not real until Finish, and a full house followed by several minutes
    /// of waiting would be the animation telling a lie the user has to sit
    /// through.
    var filledPercent: Int {
        switch self {
        case .sharingProfiles: return 5
        case .sharingAccounts: return 9
        case .receivingAccounts: return 26
        case .sharingCategories: return 31
        case .receivingCategories: return 37
        case .mergingCategories: return 58
        case .sharingTags: return 62
        case .receivingTags: return 73
        case .mergingTags: return 78
        case .buildingHousehold: return 90
        }
    }

    /// How far along, in 0...1.
    ///
    /// Read only by `HouseholdSetupCoordinator`, and always off the phase the
    /// **owner announced** — never off `mirrored`, which swaps two adjacent
    /// steps and would have the guest's percentage step backwards. See
    /// `HouseholdSetupCoordinator.fill`.
    var fill: Double { Double(filledPercent) / 100 }

    /// How much of the house this step alone adds.
    var step: Int {
        guard let previous = Self(rawValue: rawValue - 1) else { return filledPercent }
        return filledPercent - previous.filledPercent
    }

    /// The shortest this step may be on screen.
    ///
    /// Taken from the same number as the percentage, so pacing and progress
    /// cannot disagree: a step worth 4% goes by in under a second, and the
    /// one worth 21% is given room. It remains a **floor** — real work can
    /// stretch a step, nothing shortens one.
    ///
    /// The lower bound is deliberately above what the arithmetic alone would
    /// give. Two people are reading these words off two phones at once, and a
    /// step name that cannot be read is a step that may as well not be
    /// narrated.
    var minimumDuration: Duration {
        .milliseconds(700 + 30 * step)
    }

    /// The mirror image of this step on the other phone. What the owner
    /// shares, the guest is receiving, and both should be looking at a step
    /// that describes their own side of the same second.
    ///
    /// **Wording only.** Two of the swaps cross an ordinal boundary, so a
    /// mirrored phase is not a position in the sequence and nothing may
    /// derive progress from one.
    var mirrored: HouseholdCeremonyPhase {
        switch self {
        case .sharingAccounts: return .receivingAccounts
        case .receivingAccounts: return .sharingAccounts
        case .sharingCategories: return .receivingCategories
        case .receivingCategories: return .sharingCategories
        case .sharingTags: return .receivingTags
        case .receivingTags: return .sharingTags
        case .sharingProfiles, .mergingCategories, .mergingTags, .buildingHousehold: return self
        }
    }
}
