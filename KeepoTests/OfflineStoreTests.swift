import Foundation
import Testing
@testable import Keepo

/// Confirms `OfflineStore.makeContainer()` runs its file-protection call
/// against the store and its `-wal`/`-shm` siblings without throwing.
///
/// This does NOT assert the attribute reads back — confirmed empirically
/// while building this test (not merely assumed, as the phase log first
/// guessed): the iOS Simulator's `FileManager.setAttributes(
/// [.protectionKey: ...])` accepts the call and returns success, but a
/// subsequent `attributesOfItem` read on the very same path comes back
/// `nil`, every time. The Simulator has no Secure-Enclave-backed data-
/// protection subsystem at all — it isn't that protection goes unenforced
/// while still being *recorded*, the attribute doesn't persist even as
/// metadata. A real device is required for both the read-back and the
/// actual enforcement; see Phase 20's device checklist.
@Suite("Offline store file protection")
struct OfflineStoreTests {
    @Test("makeContainer's file-protection call completes without throwing")
    func fileProtectionCallSucceeds() throws {
        _ = try OfflineStore.makeContainer()

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let storeURL = directory.appendingPathComponent("Offline.store")

        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path
                )
            }
        }
    }
}
