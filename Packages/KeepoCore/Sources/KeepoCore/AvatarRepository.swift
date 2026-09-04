import Foundation
import Supabase

/// The user's own profile picture, in the private `avatars` bucket.
///
/// **Every object key is `{user_id}/{uuid}.jpg`.** The first segment is what
/// the bucket's four policies test (`storage.foldername(name)[1] =
/// auth.uid()`), and `profiles.avatar_path`'s own CHECK independently
/// requires the recorded path to start with the profile's id — so a client
/// cannot store, or point at, another user's object.
///
/// The second segment is a **fresh UUID on every upload**, never a fixed
/// `avatar.jpg`. A stable key would be served from any URL cache still
/// holding the previous bytes, which is exactly the case where the user has
/// just changed their picture and is looking at the old one. A new key is a
/// new URL, so there is nothing to invalidate.
///
/// Online-only, deliberately. Every other write in the app queues through
/// the outbox, but the outbox carries JSON payloads and this carries a file;
/// giving it a binary side-channel to make a profile picture survive
/// airplane mode is a large amount of machinery for the one write in the app
/// whose result is purely cosmetic. `CategoryRepository.deleteWithReassign`
/// is online-only for a comparable reason.
public enum AvatarRepository {
    /// The bucket, named once. Both the client and
    /// `20260910100000_profile_identity.sql` have to agree on it.
    public static let bucket = "avatars"

    /// How long a read URL stays valid. Ten minutes is far longer than the
    /// milliseconds a download takes and far shorter than a session: the URL
    /// is a bearer token for one image, so it should stop working long
    /// before anything that logged it could be read.
    public static let signedURLLifetime = 600

    /// Uploads and returns the new object key. The caller records it in
    /// `profiles.avatar_path` — this deliberately does not, so that a failed
    /// profile write leaves an orphan object rather than a profile pointing
    /// at nothing, which is the direction that degrades to "the old picture"
    /// instead of "a broken one".
    public static func upload(client: SupabaseClient, userId: UUID, jpeg: Data) async throws -> String {
        // Lowercased because that is how Postgres renders a uuid, and the
        // bucket's policies compare against `auth.uid()::text`. They compare
        // case-insensitively too, but a path that already matches the
        // server's own spelling is one fewer thing to reason about.
        let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage
            .from(bucket)
            .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
        return path
    }

    /// A time-limited URL for a private object. The bucket is not public, so
    /// this is the only way to read one — see the migration's header for why
    /// a public bucket was rejected (the URL's only secret would be a user
    /// id, which is not one).
    public static func signedURL(client: SupabaseClient, path: String) async throws -> URL {
        try await client.storage
            .from(bucket)
            .createSignedURL(path: path, expiresIn: signedURLLifetime)
    }

    /// Best-effort: a leftover object costs a few kilobytes, and failing the
    /// user's "use this new picture" because the old one would not delete
    /// would be trading something they asked for against housekeeping they
    /// did not.
    public static func remove(client: SupabaseClient, path: String) async {
        _ = try? await client.storage.from(bucket).remove(paths: [path])
    }
}
