import Foundation
@testable import TotalRekall

/// Deterministic `AppClock`. Sleepers suspend until `advance(by:)` moves virtual time past their
/// deadline. With `immediate: true`, `sleep` returns at once and time never needs advancing.
actor TestClock: AppClock {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let immediate: Bool
    private(set) var now: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var deadlineWaiters: [(deadline: Duration, continuation: CheckedContinuation<Void, Never>)] = []

    init(immediate: Bool = false) { self.immediate = immediate }

    func sleep(for duration: Duration) async throws {
        if immediate { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: now + duration, continuation: continuation)
                    wakeDeadlineWaiters()
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        now += duration
        let due = sleepers.filter { $0.value.deadline <= now }.sorted { $0.value.deadline < $1.value.deadline }
        for (id, sleeper) in due {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    func hasSleeper(deadline: Duration) -> Bool {
        sleepers.values.contains { $0.deadline == deadline }
    }

    /// Suspends until some task sleeps until exactly `deadline` (virtual time). Deterministic: no
    /// real-time polling. Only await a deadline the code under test will certainly reach.
    func waitForSleeper(deadline: Duration) async {
        if hasSleeper(deadline: deadline) { return }
        await withCheckedContinuation { deadlineWaiters.append((deadline, $0)) }
    }

    private func wakeDeadlineWaiters() {
        var waiting: [(deadline: Duration, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in deadlineWaiters {
            if hasSleeper(deadline: waiter.deadline) {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        deadlineWaiters = waiting
    }
}
