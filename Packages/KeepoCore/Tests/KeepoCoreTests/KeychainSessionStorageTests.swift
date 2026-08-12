import Foundation
import Testing
@testable import KeepoCore

/// `SecItemAdd` (a real Keychain *write*) fails with `errSecMissingEntitlement`
/// (-34018) from a plain `swift test` executable on macOS — an unsigned SPM
/// test binary has no keychain-access-group entitlement, and macOS ties
/// Keychain write access to the calling process's code signature, full
/// stop. `SecItemCopyMatching` against a key that was never written still
/// succeeds (it's a lookup that legitimately finds nothing), so that path
/// IS exercisable here. Real store/retrieve/remove round-trips are
/// Simulator/device-only — the same class of limitation `OfflineStoreTests`
/// already hit for file protection in Phase 11, and deferred the same way.
///
/// `StepUpAuthenticator` (a standalone `LAContext` biometric gate as of
/// Phase 19's real-device fix — see its own header comment) has no
/// dedicated suite here for the same reason: `canEvaluatePolicy`'s result
/// depends on the host Mac's own Touch ID/Face ID enrollment, which isn't
/// controllable from a test, and actually invoking `evaluatePolicy` would
/// either hang a headless test run waiting for a biometric prompt that can
/// never arrive, or fail unpredictably depending on the machine. Deferred
/// to manual device verification, not automated coverage.
@Suite("KeychainSessionStorage")
struct KeychainSessionStorageTests {
    @Test("retrieving a never-stored key returns nil, not an error")
    func retrieveMissingKeyReturnsNil() throws {
        let storage = KeychainSessionStorage(service: "app.keepo.session.tests")
        let key = "missing-\(UUID().uuidString)"
        #expect(try storage.retrieve(key: key) == nil)
    }
}
