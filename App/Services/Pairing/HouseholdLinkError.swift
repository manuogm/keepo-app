import Foundation

/// What can go wrong on the link itself, as opposed to on the server.
///
/// A type of its own so `run()` can tell the two apart: these already carry a
/// sentence written for this screen, and passing one through
/// `UserFacingError.describe` would replace it with the generic fallback that
/// exists for unrecognised Postgres errors.
enum HouseholdLinkError: Error {
    /// The other user backed out, optionally saying why.
    case stopped(String?)
    /// The link closed with the ceremony still waiting on it.
    case lost

    var message: String {
        switch self {
        case .stopped(let reason):
            return reason ?? "The other phone stopped before the household was built."
        case .lost:
            return "The connection to the other phone was lost. Move the phones closer and try again."
        }
    }
}
