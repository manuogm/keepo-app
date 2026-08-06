import Foundation
import Testing
@testable import KeepoCore

/// `SecItemAdd` (a real Keychain *write*) fails with `errSecMissingEntitlement`
/// (-34018) from a plain `swift test` executable on macOS regardless of
/// `accessControlFlags`/`kSecUseDataProtectionKeychain` — confirmed
/// empirically while writing this suite: an unsigned SPM test binary has no
/// keychain-access-group entitlement, and macOS ties Keychain write access
/// to the calling process's code signature, full stop. `SecItemCopyMatching`
/// against a key that was never written still succeeds (it's a lookup that
/// legitimately finds nothing), so that path IS exercisable here. Real
/// store/retrieve/remove round-trips, and the biometric gate itself, are
/// Simulator/device-only — the same class of limitation `OfflineStoreTests`
/// already hit for file protection in Phase 11, and deferred the same way.
@Suite("KeychainSessionStorage")
struct KeychainSessionStorageTests {
    @Test("retrieving a never-stored key returns nil, not an error")
    func retrieveMissingKeyReturnsNil() throws {
        let storage = KeychainSessionStorage(service: "app.keepo.session.tests", accessControlFlags: [])
        let key = "missing-\(UUID().uuidString)"
        #expect(try storage.retrieve(key: key) == nil)
    }

}

@Suite("StepUpAuthenticator")
struct StepUpAuthenticatorTests {
    @Test("throws noSession when the underlying Keychain item doesn't exist")
    func throwsWhenNoSessionStored() async throws {
        let key = "stepup-missing-\(UUID().uuidString)"
        let storage = KeychainSessionStorage(service: "app.keepo.session.tests", accessControlFlags: [])
        let authenticator = StepUpAuthenticator(storage: storage, key: key)

        await #expect(throws: StepUpError.noSession) {
            try await authenticator.requireFreshSession(reason: "Testing")
        }
    }
}
