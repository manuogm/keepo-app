import Foundation
import LocalAuthentication

/// Forces the device owner to prove it's them, right now, before a
/// high-value action (export, leaving a household, deleting the account).
///
/// An `LAContext` policy evaluation and nothing else — the OS's actual
/// documented mechanism for "prove it's you right now," with zero coupling
/// to how or where the session itself is stored.
public struct StepUpAuthenticator: Sendable {
    public init() {}

    public func requireFreshSession(reason: String) async throws {
        // `.deviceOwnerAuthentication`, **not** `...WithBiometrics`. The
        // biometrics-only policy has no fallback of any kind, so a Face ID
        // lockout (three failed matches), a declined Face ID permission
        // prompt, or a sensor that cannot see a face makes every step-up
        // action — export, leaving a household, and **deleting your
        // account** — permanently unreachable on that device, with no way
        // back short of reinstalling.
        //
        // Account deletion in particular must never be reachable only
        // through a sensor: App Store Review 5.1.1(v) requires the path to
        // exist, and a user whose face the phone will not read is exactly
        // the user who needs it. This policy still tries biometry first —
        // the prompt is identical when Face ID works — and falls through to
        // the device passcode when it does not.
        let policy: LAPolicy = .deviceOwnerAuthentication
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            throw StepUpError.noDeviceAuthentication
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
    /// The device cannot authenticate its owner at all. Under
    /// `.deviceOwnerAuthentication` this means exactly one thing — no
    /// passcode is set — since biometry being absent, unenrolled or locked
    /// out now falls through to the passcode instead of failing.
    case noDeviceAuthentication
    /// `evaluatePolicy` reported failure without an error of its own.
    case notAuthenticated
}
