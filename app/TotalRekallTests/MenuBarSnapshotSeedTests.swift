import XCTest
@testable import TotalRekall

@MainActor
final class MenuBarSnapshotSeedTests: XCTestCase {
    private struct FixedLoader: LastSnapshotDateLoading {
        let date: Date?
        func load() async -> Date? { date }
    }

    /// Signals when load() has started, then suspends until released, so a test controls seed arrival order.
    private actor GatedLoader: LastSnapshotDateLoading {
        let date: Date
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(date: Date) {
            self.date = date
            (started, startedContinuation) = AsyncStream<Void>.makeStream()
        }
        func load() async -> Date? {
            startedContinuation.yield()
            if !released { await withCheckedContinuation { continuation = $0 } }
            return date
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSeededFromDiskShowsRelativeAge() async {
        let sut = MenuBarViewModel(snapshotDateLoader: FixedLoader(date: now.addingTimeInterval(-300)))
        await sut.seedLastSnapshotDate()
        let line = sut.statusText(now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line.hasPrefix("Watching your desk · last snapshot"))
        XCTAssertFalse(line.contains("no snapshot yet"))
    }

    func testNothingOnDiskKeepsNoSnapshotYet() async {
        let sut = MenuBarViewModel(snapshotDateLoader: FixedLoader(date: nil))
        await sut.seedLastSnapshotDate()
        XCTAssertNil(sut.lastSnapshotDate)
        XCTAssertEqual(sut.statusText(now: now), "Watching your desk · no snapshot yet")
    }

    func testLiveSnapshotOverwritesSeed() async {
        let sut = MenuBarViewModel(snapshotDateLoader: FixedLoader(date: now.addingTimeInterval(-3600)))
        await sut.seedLastSnapshotDate()
        XCTAssertEqual(sut.lastSnapshotDate, now.addingTimeInterval(-3600), "seed applied first")
        sut.lastSnapshotDate = now
        XCTAssertEqual(sut.lastSnapshotDate, now, "live snapshot replaces the seed")
    }

    func testSeedArrivingAfterNewerLiveSnapshotIsIgnored() async {
        let loader = GatedLoader(date: now.addingTimeInterval(-3600))
        let sut = MenuBarViewModel(snapshotDateLoader: loader)
        let seeding = Task { await sut.seedLastSnapshotDate() }
        var startedIterator = loader.started.makeAsyncIterator()
        await startedIterator.next()  // load() has begun and is suspended on the gate
        sut.lastSnapshotDate = now
        await loader.release()
        await seeding.value
        XCTAssertEqual(sut.lastSnapshotDate, now)
    }
}
