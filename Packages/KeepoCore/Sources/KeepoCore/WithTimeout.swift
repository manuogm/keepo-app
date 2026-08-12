import Foundation

public enum TimeoutError: Error {
    case timedOut
}

/// Caps a read that has a cache/offline fallback at `seconds`, so falling
/// back doesn't mean first waiting out the default ~60s URLRequest timeout
/// (`SupabaseConfig.makeSupabaseClient` sets no custom `URLSessionConfiguration`).
/// Never used to cap a write — a write should keep running to completion or
/// genuine network failure; racing it against a clock and abandoning it
/// client-side would leave the caller unsure whether the write actually
/// landed, which a read has no equivalent risk for.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError.timedOut
        }
        return result
    }
}
