import Foundation

/// Forces a fresh biometric check before a high-value action (export,
/// account deletion, household invite accept/leave) — spec. Implemented as
/// a forced re-read of the same Keychain item the session itself lives in,
/// never a trusted-in-memory flag: the OS/Secure Enclave enforces this, not
/// an in-app `LAContext` boolean a patched binary could flip.
///
/// A thin wrapper, not a second seam — every caller goes through
/// `AuthProvider.stepUp(reason:)`; this is what that method calls for any
/// provider actually backed by `KeychainSessionStorage`.
public struct StepUpAuthenticator: Sendable {
    private let storage: KeychainSessionStorage
    private let key: String

    public init(
        storage: KeychainSessionStorage = KeychainSessionStorage(),
        key: String = KeychainSessionStorage.sessionStorageKey
    ) {
        self.storage = storage
        self.key = key
    }

    public func requireFreshSession(reason: String) async throws {
        guard try storage.retrieve(key: key, prompt: reason) != nil else {
            throw StepUpError.noSession
        }
    }
}

public enum StepUpError: Error, Equatable {
    /// No session item exists to re-read at all — the caller should be
    /// signed out already, this is a "shouldn't happen" guard, not the
    /// expected declined-biometric path (that's a thrown Keychain OSStatus
    /// from `KeychainSessionStorage` itself, surfaced unchanged).
    case noSession
}
