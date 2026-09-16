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

/// Deleting the app leaves the Keychain item behind — that is iOS working as
/// designed, and it meant a reinstall signed the previous user straight back
/// in with no way to reach a sign-in screen. `UserDefaults` is wiped with the
/// container, so its emptiness is the signal that the install is new.
///
/// These assert the *decision* and the marker. The `SecItemDelete` behind it
/// is device-only for the entitlement reason the suite above documents, so
/// what is pinned here is that the purge runs exactly once per install and
/// never touches a session the user still wants.
@Suite("A reinstall does not inherit the last user's session")
struct KeychainReinstallPurgeTests {
    /// Its own suite name every time: `UserDefaults` is process-wide, and a
    /// shared one would make these order-dependent.
    private func freshDefaults() throws -> UserDefaults {
        let suite = "keepo.tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test("the first launch after an install purges, and records that it did")
    func firstLaunchPurges() throws {
        let defaults = try freshDefaults()
        #expect(KeychainSessionStorage.purgeSessionIfReinstalled(
            defaults: defaults, storage: KeychainSessionStorage(service: "app.keepo.session.tests")
        ))
        #expect(defaults.bool(forKey: KeychainSessionStorage.installMarkerKey))
    }

    /// The property that matters most: a signed-in user who simply opens the
    /// app again must keep their session. Purging on every launch would sign
    /// everyone out constantly, which is a worse bug than the one being fixed.
    @Test("every launch after the first leaves the session alone")
    func laterLaunchesDoNotPurge() throws {
        let defaults = try freshDefaults()
        let storage = KeychainSessionStorage(service: "app.keepo.session.tests")
        _ = KeychainSessionStorage.purgeSessionIfReinstalled(defaults: defaults, storage: storage)

        #expect(KeychainSessionStorage.purgeSessionIfReinstalled(
            defaults: defaults, storage: storage
        ) == false)
        #expect(KeychainSessionStorage.purgeSessionIfReinstalled(
            defaults: defaults, storage: storage
        ) == false)
    }

    /// Both the app launch and a Shortcuts-triggered capture call this, and
    /// either can be first after a reinstall. Whichever wins purges once; the
    /// other must not purge again behind it.
    @Test("a second entry point after the first sees the marker and stands down")
    func onlyOneEntryPointPurges() throws {
        let defaults = try freshDefaults()
        let launch = KeychainSessionStorage.purgeSessionIfReinstalled(
            defaults: defaults, storage: KeychainSessionStorage(service: "app.keepo.session.tests")
        )
        let capture = KeychainSessionStorage.purgeSessionIfReinstalled(
            defaults: defaults, storage: KeychainSessionStorage(service: "app.keepo.session.tests")
        )
        #expect(launch)
        #expect(capture == false)
    }
}
