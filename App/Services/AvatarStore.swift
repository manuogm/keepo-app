import KeepoCore
import Observation
import Supabase
import SwiftUI
import UIKit

/// The user's avatar, downscaled on the way up and cached on the way down.
///
/// Two jobs that belong together because they share one fact — the object
/// key. Uploading produces a key; rendering needs the bytes behind one; and
/// the cache is keyed on it, which is only safe because
/// `AvatarRepository.upload` mints a fresh UUID per upload (a stable key
/// would make a changed picture indistinguishable from an unchanged one).
///
/// The cache is a file on disk, not a `URLCache` entry: the bucket is
/// private, so every read goes through a **signed URL that expires**, and a
/// cache keyed on a URL that changes every ten minutes would never hit.
@Observable
@MainActor
final class AvatarStore {
    /// The image for the profile's current `avatar_path`, once loaded. Nil
    /// means "not loaded yet or none set" — the views fall back to the
    /// initial, which is what they drew before avatars existed.
    private(set) var image: UIImage?
    private(set) var isBusy = false
    /// Why the last upload or removal failed, for the screen to render.
    /// A photo that silently does not change is the worst of the three
    /// outcomes: the user cannot tell it from a slow network, and will
    /// try again forever.
    private(set) var lastError: String?

    /// The key `image` belongs to, so a second `load` for the same path is a
    /// no-op and a pull that changes the path is not.
    private var loadedPath: String?

    /// 512pt square. An avatar is drawn at 80pt at its largest
    /// (`Size.illustration`), so 512 covers a 3× screen with room to spare
    /// and still encodes to well under 200 KB — comfortably inside the
    /// bucket's own 2 MiB ceiling, which is a backstop and not a target.
    private static let maxDimension: CGFloat = 512
    private static let jpegQuality: CGFloat = 0.8

    func load(path: String?, client: SupabaseClientProviding) async {
        guard let path else {
            image = nil
            loadedPath = nil
            return
        }
        guard path != loadedPath else { return }

        if let cached = Self.cachedImage(for: path) {
            image = cached
            loadedPath = path
            return
        }

        guard let url = try? await AvatarRepository.signedURL(client: client.client, path: path),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let downloaded = UIImage(data: data) else { return }

        Self.writeCache(data, for: path)
        image = downloaded
        loadedPath = path
    }

    /// Uploads, records the new path on the profile, and deletes the object
    /// the profile used to point at — in that order, so the moment anything
    /// fails the profile still names an object that exists. Returns the new
    /// path, or nil if the upload or the profile write failed.
    func replace(with picked: UIImage, session: SessionStore) async -> String? {
        lastError = nil
        guard let userId = session.profile?.id else {
            lastError = "You are not signed in."
            return nil
        }
        guard let jpeg = Self.downscaledJPEG(picked) else {
            lastError = "That image could not be read."
            return nil
        }
        isBusy = true
        defer { isBusy = false }

        let previous = session.profile?.avatarPath
        do {
            let path = try await AvatarRepository.upload(client: session.client, userId: userId, jpeg: jpeg)
            try await ProfileRepository.updateAvatarPath(
                client: session.client, userId: userId, avatarPath: path
            )
            Self.writeCache(jpeg, for: path)
            image = picked
            loadedPath = path
            try await session.refreshProfile()
            // Every other screen that draws the user reads it through the
            // refresh token, the scope banner's avatar included — without
            // this the picture changes on Profile and stays the old initial
            // on the four tabs behind it.
            session.refresh.bump()
            if let previous { await AvatarRepository.remove(client: session.client, path: previous) }
            return path
        } catch {
            lastError = UserFacingError.describe(error)
            return nil
        }
    }

    /// Clears the profile's pointer first and only then removes the object:
    /// a profile naming a deleted object renders as a broken avatar, while
    /// an orphan object renders as nothing at all.
    func removeAvatar(session: SessionStore) async {
        guard let userId = session.profile?.id, let path = session.profile?.avatarPath else { return }
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await ProfileRepository.updateAvatarPath(
                client: session.client, userId: userId, avatarPath: nil
            )
        } catch {
            lastError = UserFacingError.describe(error)
            return
        }
        image = nil
        loadedPath = nil
        Self.clearCache(for: path)
        await AvatarRepository.remove(client: session.client, path: path)
        try? await session.refreshProfile()
        session.refresh.bump()
    }

    // MARK: - Encoding

    /// Aspect-fills a centre square, then scales to `maxDimension`.
    ///
    /// Square first, not last: an avatar is drawn in a circle, so a portrait
    /// photo scaled to fit would be letterboxed inside that circle with the
    /// face somewhere near the top. Cropping to the centre square is what
    /// makes "the middle of the picture" the thing inside the circle, which
    /// is where people put faces.
    static func downscaledJPEG(_ image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let target = min(side, maxDimension)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        let squared = renderer.image { _ in
            image.draw(in: CGRect(
                x: -origin.x * target / side, y: -origin.y * target / side,
                width: image.size.width * target / side, height: image.size.height * target / side
            ))
        }
        return squared.jpegData(compressionQuality: jpegQuality)
    }

    // MARK: - Disk cache

    /// Caches, not Application Support: an avatar is re-downloadable from the
    /// server, so it belongs where the OS is allowed to reclaim it under
    /// storage pressure. Losing it costs one signed-URL round trip.
    private static func cacheURL(for path: String) -> URL? {
        guard let directory = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = directory.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The key contains a "/", which is a path separator — flattened, or
        // every write would land in a per-user subdirectory that does not
        // exist and silently fail.
        return folder.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private static func cachedImage(for path: String) -> UIImage? {
        guard let url = cacheURL(for: path), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func writeCache(_ data: Data, for path: String) {
        guard let url = cacheURL(for: path) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func clearCache(for path: String) {
        guard let url = cacheURL(for: path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The one thing `AvatarStore.load` needs from a session, so a preview or a
/// test can hand it a client without building a whole `SessionStore`.
protocol SupabaseClientProviding {
    var client: SupabaseClient { get }
}

extension SessionStore: SupabaseClientProviding {}
