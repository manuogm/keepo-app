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
}

public func makeSupabaseClient(config: SupabaseConfig) -> SupabaseClient {
    SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
}
