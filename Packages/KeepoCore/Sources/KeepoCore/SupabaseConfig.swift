import Foundation
import Supabase

/// The two values every Supabase client needs. Read from Info.plist
/// (xcconfig-injected — see Config/Debug.xcconfig.example) by the app target,
/// never hardcoded and never committed as real values.
public struct SupabaseConfig: Sendable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// True for the local dev stack (`supabase start`), false for any hosted
    /// project. `StubAuthProvider` refuses to run against anything else —
    /// see its initializer.
    public var isLocal: Bool {
        url.host == "127.0.0.1" || url.host == "localhost"
    }

    /// Both `SessionStore.init()` and `CaptureIntent.perform()` (Phase 12)
    /// read the same Info.plist keys — the one place, so a config typo is
    /// one fix, not two. `SessionStore` still `fatalError`s on failure (a
    /// misconfigured build is unusable either way); an Intent should not
    /// crash the host app over it, so this throws instead and lets the
    /// caller decide.
    public static func fromInfoPlist(bundle: Bundle = .main) throws -> SupabaseConfig {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let url = URL(string: urlString),
            let anonKey = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !anonKey.isEmpty
        else {
            throw SupabaseConfigError.missingInfoPlistKeys
        }
        return SupabaseConfig(url: url, anonKey: anonKey)
    }
}

public enum SupabaseConfigError: Error {
    case missingInfoPlistKeys
}

public func makeSupabaseClient(config: SupabaseConfig) -> SupabaseClient {
    SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
}
