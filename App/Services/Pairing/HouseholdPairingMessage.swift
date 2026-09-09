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
/// So this protocol carries exactly three things: who you are (so the other
/// phone can draw your face before a household exists and RLS would rightly
/// refuse), one single-use invite token, and where each side has got to in
/// the ceremony. The animation is a narration of real server work, and this
/// is the wire it is narrated over.
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
    /// Sent by both sides the instant the session connects.
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
struct HouseholdPairingIdentity: Codable, Hashable, Sendable {
    static let protocolVersion = 1
    static let maxAvatarBytes = 24_000

    var protocolVersion: Int = HouseholdPairingIdentity.protocolVersion
    /// The user's own id. Checked against the invite on the owner's side so a
    /// phone cannot pair with itself across two simulators signed into one
    /// account — which is exactly how this gets tested, and would otherwise
    /// fail deep inside `accept_invite` with "cannot accept your own invite".
    let userId: UUID
    let displayName: String?
    let email: String?
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

    /// The name to draw, never blank. Same fallback ladder as
    /// `ProfileAvatarView`: a chosen name, then the address they signed up
    /// with, then a word rather than an empty label.
    var resolvedName: String {
        let candidates = [displayName, email].compactMap {
            $0?.trimmingCharacters(in: .whitespaces)
        }
        return candidates.first { !$0.isEmpty } ?? "Keepo user"
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

    /// How full the house is once this step is done.
    ///
    /// The last step stops at 0.9, not 1.0. The house is deliberately left
    /// unfinished while the owner reviews the report and the guest waits —
    /// the household is not real until the owner presses Finish, and a full
    /// house followed by several minutes of waiting would be the animation
    /// telling a lie the user has to sit through.
    var fill: Double {
        Double(rawValue + 1) / Double(Self.allCases.count) * 0.9
    }

    /// The mirror image of this step on the other phone. What the owner
    /// shares, the guest is receiving, and both should be looking at a step
    /// that describes their own side of the same second.
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
