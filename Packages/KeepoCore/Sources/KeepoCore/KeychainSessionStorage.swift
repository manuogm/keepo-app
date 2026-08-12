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

public enum KeychainSessionStorageError: Error, Equatable {
    case accessControlCreationFailed
    case osStatus(OSStatus)
}
