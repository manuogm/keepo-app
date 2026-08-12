import Foundation
import LocalAuthentication

/// Forces a fresh biometric check before a high-value action (export,
/// leave/erase household) — spec.
///
/// **Not** a re-read of the session's own Keychain item (an earlier design;
/// see this file's git history and `lessons-learned.md`'s "first real-
/// device run" entry). Storing the ordinary session behind a biometric ACL
/// meant `supabase-swift` re-triggered Face ID on *every* authenticated
/// request — not just step-up — since it reads the stored session before
/// attaching the bearer token to any API call. That's invisible in the
/// Simulator (no biometric hardware to gate against at all) and only
/// surfaced on a real device. A standalone `LAContext` policy evaluation is
/// the OS's actual documented mechanism for "prove it's you right now,"
/// with zero coupling to how or where the session itself is stored.
public struct StepUpAuthenticator: Sendable {
    public init() {}

    public func requireFreshSession(reason: String) async throws {
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            throw StepUpError.biometricsUnavailable
        }

        let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }

        guard success else {
            throw StepUpError.notAuthenticated
        }
    }
}

public enum StepUpError: Error, Equatable {
    /// No biometric hardware, none enrolled, or the device is otherwise
    /// unable to evaluate the policy at all — distinct from the user
    /// actively declining, which surfaces as `.notAuthenticated` or the
    /// underlying `LAError` thrown by `evaluatePolicy` itself.
    case biometricsUnavailable
    case notAuthenticated
}
