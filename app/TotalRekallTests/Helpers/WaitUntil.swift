import Foundation

/// Deterministic, time-bounded wait for asynchronous test conditions.
///
/// Polls `condition` with a short real sleep until it holds or `timeout` elapses, so the outcome does not
/// depend on machine speed (a fixed number of `Task.yield()`s is not enough on slow CI runners).
/// Returns whether the condition became true; callers must assert on the result.
/// Inherits the caller's actor isolation, so `@MainActor` test classes can read main-actor state directly.
func waitUntil(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
