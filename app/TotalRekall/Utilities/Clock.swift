import Foundation

/// Injectable time source for debounce logic. Named `AppClock` (not `Clock`) so it never
/// shadows Swift's standard-library `Clock` protocol. The test double (`TestClock`) lives in
/// the unit-test target.
protocol AppClock: Sendable {
    /// Suspends for `duration`. Throws `CancellationError` if the calling task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// Real implementation backed by `Task.sleep`.
struct SystemClock: AppClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
