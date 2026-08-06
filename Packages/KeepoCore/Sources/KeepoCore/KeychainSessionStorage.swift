import Auth
import Foundation
import LocalAuthentication
import Security

/// A Keychain-backed `AuthLocalStorage` whose item is protected by a real
/// `SecAccessControl`, not the SDK's own plain `KeychainLocalStorage`
/// (`makeSupabaseClient` passed no options at all before this phase, so the
/// refresh token sat in the default Keychain item with default
/// accessibility). `.biometryCurrentSet` is what makes this a genuine
/// device-changed-hands signal: it auto-invalidates the moment a new face
/// is enrolled, forcing a real re-login — the OS enforces that, not app
/// code (spec).
///
/// `accessControlFlags` is a constructor parameter, not a hardcoded
/// literal — an empty set stores under plain `kSecAttrAccessible` (no ACL
/// object at all), which is what a non-biometric-hardware fallback would
/// use; the production call site (`SessionStore`) passes
/// `[.biometryCurrentSet]`. Note this doesn't make writes unit-testable
/// either way — see `KeychainSessionStorageTests`' own header comment for
/// why real `SecItemAdd` calls aren't exercisable from `swift test` at all.
public struct KeychainSessionStorage: AuthLocalStorage {
    /// The one key both `SessionStore` (via `SupabaseClientOptions`) and
    /// `StepUpAuthenticator` must agree on — GoTrue itself would otherwise
    /// pick its own default, and a step-up re-read against the wrong key
    /// would silently never find the real session.
    public static let sessionStorageKey = "keepo-session"

    private let service: String
    private let accessControlFlags: SecAccessControlCreateFlags

    public init(
        service: String = "app.keepo.session", accessControlFlags: SecAccessControlCreateFlags = [.biometryCurrentSet]
    ) {
        self.service = service
        self.accessControlFlags = accessControlFlags
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
        // A delete-then-add, not SecItemUpdate — updating an existing
        // biometric-protected item's VALUE still requires evaluating its
        // current access control to authorize the update, exactly the
        // repeated-prompt problem this avoids. Deleting by primary key
        // (service+account) needs no such evaluation; SecItemDelete never
        // touches the protected value.
        try? remove(key: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = value

        // An empty flag set (the test-only configuration) skips
        // `SecAccessControl` entirely rather than constructing one with no
        // flags — an unsigned SPM test binary can't create an ACL-protected
        // item at all (`errSecMissingEntitlement`, confirmed empirically),
        // ACL or not, so plain `kSecAttrAccessible` is what actually lets
        // `KeychainSessionStorageTests` exercise real store/retrieve/remove
        // calls. The production path (non-empty flags) still gets a real
        // `SecAccessControl`.
        if accessControlFlags.isEmpty {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        } else {
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, accessControlFlags, nil
            ) else {
                throw KeychainSessionStorageError.accessControlCreationFailed
            }
            query[kSecAttrAccessControl as String] = access
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSessionStorageError.osStatus(status)
        }
    }

    public func retrieve(key: String) throws -> Data? {
        try retrieve(key: key, prompt: nil)
    }

    /// Not part of `AuthLocalStorage` — `StepUpAuthenticator` calls this
    /// overload directly so the system Face ID sheet shows the actual
    /// reason for the re-check ("Confirm it's you to export your data")
    /// instead of a generic prompt.
    public func retrieve(key: String, prompt: String?) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        if let prompt {
            let context = LAContext()
            context.localizedReason = prompt
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
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
