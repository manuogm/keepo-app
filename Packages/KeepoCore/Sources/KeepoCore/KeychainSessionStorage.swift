import Auth
import Foundation
import LocalAuthentication
import Security

/// A Keychain-backed `AuthLocalStorage` using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// — stronger than the SDK's own plain `KeychainLocalStorage` (`makeSupabaseClient`
/// passed no options at all before Phase 17, so the refresh token sat in
/// the default Keychain item with default accessibility), but deliberately
/// **not** behind a biometric `SecAccessControl`.
///
/// An earlier design protected this item with `.biometryCurrentSet` and
/// implemented step-up (`StepUpAuthenticator`) as a forced re-read of it.
/// That broke the app on a real device: `supabase-swift` reads the stored
/// session before *every* authenticated request to attach the bearer
/// token, so a biometric-gated session item meant Face ID fired on every
/// single API call, not just step-up — invisible in the Simulator (no
/// biometric hardware to gate against at all), only surfacing on real
/// hardware. See `lessons-learned.md`'s "first real-device run" entry.
/// Step-up is now a fully independent `LAContext` policy evaluation with no
/// coupling to how the session itself is stored.
public struct KeychainSessionStorage: AuthLocalStorage {
    public static let sessionStorageKey = "keepo-session"

    private let service: String

    public init(service: String = "app.keepo.session") {
        self.service = service
    }

    /// `kSecUseDataProtectionKeychain` — without it, a bare SPM test
    /// executable on macOS (no keychain-access-group entitlement, unlike a
    /// real iOS app/Simulator process) fails every `SecItem*` call with
    /// `errSecMissingEntitlement` (-34018), confirmed empirically while
    /// writing `KeychainSessionStorageTests`. Harmless to always include:
    /// iOS's keychain is already the data-protection keychain by default.
    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    public func store(key: String, value: Data) throws {
        // A delete-then-add, not SecItemUpdate — simpler and consistent
        // regardless of whether the item exists yet, no ACL-evaluation
        // subtlety to reason about now that there's no ACL at all.
        try? remove(key: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSessionStorageError.osStatus(status)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        // LAContext.interactionNotAllowed = true prevents a Face ID prompt —
        // if the stored item has a biometric SecAccessControl from an older
        // build, this returns errSecInteractionNotAllowed instead of
        // triggering the system biometric sheet. We delete that stale item
        // and return nil so the caller falls through to a fresh sign-in,
        // which stores a new item under the plain
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly ACL.
        let noInteractionContext = LAContext()
        noInteractionContext.interactionNotAllowed = true
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = noInteractionContext

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            try? remove(key: key)
            return nil
        default:
            throw KeychainSessionStorageError.osStatus(status)
        }
    }

    public func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSessionStorageError.osStatus(status)
        }
    }
}

extension KeychainSessionStorage {
    /// The marker whose **absence** means this install is new. It lives in
    /// `UserDefaults`, which is the entire trick: iOS deletes an app's
    /// container — Preferences included — when the app is deleted, and
    /// deliberately does *not* delete its Keychain items. Absence is
    /// therefore not "we never wrote it", it is "the container this would
    /// have been written into no longer exists."
    static let installMarkerKey = "keepo.hasLaunchedSinceInstall"

    /// Removes a stored session that outlived the app it belonged to.
    ///
    /// **Deleting the app is not signing out, and every user believes it
    /// is.** Keychain items survive an uninstall by design — they are
    /// scoped to the app's keychain access group, not to its container — so
    /// deleting Keepo, reinstalling it and launching restored the previous
    /// refresh token and signed the user straight back in, with no sign-in
    /// screen and no way to reach one. Reported from a real device after a
    /// delete-and-rebuild, and it is worse than a surprise: on a shared or
    /// resold phone the next person to install Keepo inherits the last
    /// person's financial history.
    ///
    /// Reinstalling is the one gesture every user already knows for "start
    /// over", so this makes it mean that. A session the user actually wants
    /// kept is untouched — the marker is written on first launch and
    /// survives every launch after it.
    ///
    /// Only Keepo's own item is removed, under Keepo's own service. The
    /// local dev stack's SDK-default storage lives elsewhere and is left
    /// alone, which costs nothing: `StubAuthProvider` signs itself in there
    /// regardless.
    ///
    /// Returns whether it purged, which is what the tests assert — the
    /// `SecItemDelete` itself is device-only, for the entitlement reason
    /// this file's test suite documents at length.
    @discardableResult
    public static func purgeSessionIfReinstalled(
        defaults: UserDefaults = .standard,
        storage: KeychainSessionStorage = KeychainSessionStorage()
    ) -> Bool {
        guard !defaults.bool(forKey: installMarkerKey) else { return false }
        // `try?`, not `try`: a fresh install has no item to remove and
        // `remove` already treats `errSecItemNotFound` as success, so the
        // only errors reachable here are ones where refusing to launch
        // would be a far worse answer than launching signed out.
        try? storage.remove(key: sessionStorageKey)
        defaults.set(true, forKey: installMarkerKey)
        return true
    }
}

public enum KeychainSessionStorageError: Error, Equatable {
    case accessControlCreationFailed
    case osStatus(OSStatus)
}
