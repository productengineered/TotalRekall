import XCTest
@testable import TotalRekall

/// Per-desk learned layouts (per-desk layouts): the store, the lookup rules, snapshot gating and seeding.
final class PerDeskLayoutTests: XCTestCase {
    private func layout(_ serials: [String], flipped: Bool = false) -> MonitorLayout {
        var map: [String: MonitorLayout.Origin] = [:]
        let ordered = flipped ? serials.reversed() : serials
        for (index, serial) in ordered.enumerated() { map[serial] = .init(x: index * 1000, y: 0) }
        return MonitorLayout(origins: map)
    }

    private func learn(_ layout: MonitorLayout, into store: LearnedLayoutStore, gate: SnapshotGate = SnapshotGate()) async throws {
        let learned = await store.learn(layout, ifGate: try XCTUnwrap(gate.token()))
        XCTAssertTrue(learned)
    }

    private func display(_ serial: String, x: Int) -> DisplaySnapshot {
        DisplaySnapshot(vendorID: 1, productID: 1, serialNumber: serial, panelSerial: serial, unitNumber: 0,
                        iokitLocationPath: nil, resolution: SnapshotSize(width: 100, height: 100),
                        scaleFactor: 1, displayName: serial, originX: x, originY: 0, isMain: x == 0, cgDisplayID: nil)
    }

    private func window(_ id: UInt32) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.example", appName: "App", windowID: id, windowTitle: "W\(id)",
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: "builtin", spaceOrdinal: 1,
            spaceUUID: nil, spaceIndex: 0, frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10),
            isFullscreen: false, isMinimized: false, zOrder: 0
        )
    }

    private func config(_ serials: [String], windows: Int, date: TimeInterval = 0) -> (String, DisplayConfigSnapshot) {
        let key = SnapshotKey.make(panelSerials: serials)
        let value = DisplayConfigSnapshot(
            fingerprint: key, displayConfigName: "t",
            displays: serials.enumerated().map { display($1, x: $0 * 1000) },
            lastSnapshotDate: Date(timeIntervalSince1970: date),
            windows: (0..<windows).map { window(UInt32($0 + 1)) })
        return (key, value)
    }

    // MARK: Keys and lookup

    func testDeskKeyIgnoresBuiltinUnlessAlone() {
        XCTAssertEqual(DeskKey.make(for: layout(["builtin", "X", "Y"])), DeskKey.make(for: layout(["Y", "X"])))
        XCTAssertNotNil(DeskKey.make(for: layout(["builtin"])))
        XCTAssertNotEqual(DeskKey.make(for: layout(["builtin"])), DeskKey.make(for: layout(["builtin", "X"])))
        XCTAssertNil(DeskKey.make(for: MonitorLayout(origins: [:])))
    }

    /// C2 (13): a laptop-only set is its own desk and works.
    func testBuiltinOnlyIsItsOwnDesk() async throws {
        let store = LearnedLayoutStore()
        try await learn(layout(["builtin"]), into: store)
        let same = await store.lookup(live: layout(["builtin"]))
        XCTAssertEqual(same.match, .knownDesk)
        let docked = await store.lookup(live: layout(["builtin", "X", "Y"]))
        XCTAssertEqual(docked.match, .newDesk)
        XCTAssertTrue(docked.layout.origins.isEmpty)
    }

    func testDesksGetDefaultNamesInOrder() async throws {
        let store = LearnedLayoutStore()
        try await learn(layout(["A", "B"]), into: store)
        try await learn(layout(["C", "D"]), into: store)
        try await learn(layout(["A", "B"], flipped: true), into: store)  // same desk again
        let desks = await store.desks
        XCTAssertEqual(desks.map(\.name), ["Desk 1", "Desk 2"])
        XCTAssertEqual(desks.first?.key, DeskKey.make(for: layout(["A", "B"])))
    }

    /// RCA (4): a swap present at the first dock of a new desk is learned as correct (accepted risk).
    func testSwapAtFirstDockOfNewDeskIsLearnedAsCorrect() async throws {
        let store = LearnedLayoutStore()
        let swapped = layout(["A", "B"], flipped: true)
        let before = await store.lookup(live: swapped)
        XCTAssertEqual(before.match, .newDesk)
        try await learn(swapped, into: store)
        let after = await store.lookup(live: swapped)
        XCTAssertEqual(after.match, .knownDesk)
        XCTAssertEqual(SwapDetector.detect(learned: after.layout, live: swapped), .correct)
    }

    /// C2 (11): desk 1 -> desk 2 -> desk 1: desk 1 keeps its own layout, so a swap there is detected.
    func testKnownDeskKeepsItsOwnLayoutAfterVisitingAnother() async throws {
        let store = LearnedLayoutStore()
        let desk1 = layout(["A", "B"])
        try await learn(desk1, into: store)
        try await learn(layout(["C", "D"]), into: store)
        let back = await store.lookup(live: layout(["A", "B"], flipped: true))
        XCTAssertEqual(back.layout, desk1)
        guard case .swapped = SwapDetector.detect(learned: back.layout, live: layout(["A", "B"], flipped: true)) else {
            return XCTFail("expected a swap against desk 1's own layout")
        }
    }

    // MARK: Swap detector ignores the built-in display

    /// RCA (6): lid open vs closed differ only by the built-in entry.
    func testSwapDetectorIgnoresBuiltinWhenOnlyDifference() {
        let learned = layout(["builtin", "X", "Y"])
        let closed = MonitorLayout(origins: ["X": learned.origins["X"] ?? .init(x: 0, y: 0),
                                             "Y": learned.origins["Y"] ?? .init(x: 0, y: 0)])
        XCTAssertEqual(SwapDetector.detect(learned: learned, live: closed), .correct)
        let swapped = MonitorLayout(origins: ["X": closed.origins["Y"] ?? .init(x: 0, y: 0),
                                              "Y": closed.origins["X"] ?? .init(x: 0, y: 0)])
        guard case .swapped(let plan) = SwapDetector.detect(learned: learned, live: swapped) else {
            return XCTFail("expected swapped")
        }
        XCTAssertNil(plan.targets["builtin"])
    }

    // MARK: Snapshot gating

    private actor CountingCapturer: SnapshotCapturing {
        private(set) var calls = 0
        let layoutToReturn: MonitorLayout
        init(layout: MonitorLayout) { layoutToReturn = layout }
        func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
            calls += 1
            return SnapshotCaptureResult(reason: reason, outcome: .written, layout: layoutToReturn,
                                         configKey: "k", windowCount: 3)
        }
    }

    /// RCA (8): a manual save at an unknown docked set succeeds and learns that desk.
    func testManualSaveAtNewDeskSucceedsAndLearns() async throws {
        let store = LearnedLayoutStore()
        try await learn(layout(["builtin"]), into: store)
        let docked = layout(["builtin", "X", "Y"])
        let capturer = CountingCapturer(layout: docked)
        let coord = SnapshotCoordinator(capturer: capturer, gate: SnapshotGate(), learnedStore: store,
                                        liveLayout: { docked })
        let result = await coord.saveManually()
        XCTAssertEqual(result, .saved(windowCount: 3))
        let deskKeys = await store.desks.map(\.key)
        XCTAssertEqual(deskKeys, [DeskKey.make(for: docked)].compactMap { $0 },
                       "only the docked desk is registered; the built-in-only layout is kept but is not a desk")
    }

    /// C2 (9): a strict subset of a known desk writes no snapshot and learns no new desk.
    func testSubsetOfKnownDeskWritesNothing() async throws {
        let store = LearnedLayoutStore()
        try await learn(layout(["A", "B", "C"]), into: store)
        let partial = layout(["A", "B"])
        let capturer = CountingCapturer(layout: partial)
        let coord = SnapshotCoordinator(capturer: capturer, gate: SnapshotGate(), learnedStore: store,
                                        liveLayout: { partial })
        let result = await coord.saveManually()
        XCTAssertEqual(result, .refused(message: SnapshotRefusal.dockedSetAbsent.message))
        let calls = await capturer.calls
        let desks = await store.desks
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(desks.count, 1)
    }

    /// C2 (12): the pause-side lookup resolves through the live key, not a global value.
    func testCoordinatorLookupUsesLiveKey() async throws {
        let store = LearnedLayoutStore()
        let desk1 = layout(["A", "B"])
        let desk2 = layout(["C", "D"])
        try await learn(desk1, into: store)
        try await learn(desk2, into: store)
        let coord = SnapshotCoordinator(capturer: CountingCapturer(layout: desk1), gate: SnapshotGate(),
                                        learnedStore: store, liveLayout: { desk1 })
        let lookup1 = await coord.deskLookup(live: desk1)
        let lookup2 = await coord.deskLookup(live: desk2)
        XCTAssertEqual(lookup1.layout, desk1)
        XCTAssertEqual(lookup2.layout, desk2)
    }

    // MARK: Seeding from snapshots.json

    /// RCA (7) and C2 (15): layouts survive relaunch by seeding from snapshots.json, and a
    /// configuration with no windows is ignored exactly as restore ignores it (loadContext).
    func testSeedsFromSnapshotsAndIgnoresEmptyWindowConfigs() async {
        let (k1, c1) = config(["builtin", "A", "B"], windows: 2, date: 10)
        let (k2, c2) = config(["builtin", "C", "D"], windows: 0, date: 20)  // e.g. a cleared snapshot
        let file = SnapshotFile(configurations: [k1: c1, k2: c2])
        let store = LearnedLayoutStore(seedSource: { file })
        let known = await store.lookup(live: layout(["A", "B"]))
        XCTAssertEqual(known.match, .knownDesk)
        XCTAssertEqual(known.layout.origins["A"], .init(x: 1000, y: 0))
        let empty = await store.lookup(live: layout(["builtin", "C", "D"]))
        XCTAssertEqual(empty.match, .newDesk)
        let desks = await store.desks
        XCTAssertEqual(desks.map(\.name), ["Desk 1"])
    }

    func testSeedPrefersNewestOfLidOpenAndLidClosedConfigs() async {
        let (k1, open) = config(["builtin", "A", "B"], windows: 2, date: 10)
        let (k2, closed) = config(["A", "B"], windows: 2, date: 20)
        let store = LearnedLayoutStore(seedSource: { SnapshotFile(configurations: [k1: open, k2: closed]) })
        let lookup = await store.lookup(live: layout(["A", "B"]))
        XCTAssertEqual(lookup.layout.origins.keys.sorted(), ["A", "B"])
        let desks = await store.desks
        XCTAssertEqual(desks.count, 1)
    }

    func testFailedSeedRetriesOnNextLookup() async {
        struct Boom: Error {}
        let (key, value) = config(["A", "B"], windows: 1)
        let attempts = Attempts()
        let store = LearnedLayoutStore(seedSource: {
            if attempts.bump() == 1 { throw Boom() }
            return SnapshotFile(configurations: [key: value])
        })
        let first = await store.lookup(live: layout(["A", "B"]))
        XCTAssertEqual(first.match, .newDesk)
        let second = await store.lookup(live: layout(["A", "B"]))
        XCTAssertEqual(second.match, .knownDesk)
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    // MARK: Registration needs an external panel

    func testBuiltinOnlyLayoutIsKeptButNeverRegisteredAsADesk() async throws {
        let (key, builtinOnly) = config(["builtin"], windows: 2, date: 10)
        let seeded = LearnedLayoutStore(seedSource: { SnapshotFile(configurations: [key: builtinOnly]) })
        let seededLookup = await seeded.lookup(live: layout(["builtin"]))
        XCTAssertEqual(seededLookup.match, .knownDesk)
        let seededDesks = await seeded.desks
        XCTAssertTrue(seededDesks.isEmpty)

        let store = LearnedLayoutStore()
        try await learn(layout(["builtin"]), into: store)
        let relearned = await store.relearn(layout(["builtin"]), deskKey: DeskKey.make(for: layout(["builtin"])) ?? "")
        XCTAssertTrue(relearned)
        let storedLayout = await store.layout(forLive: layout(["builtin"]))
        XCTAssertFalse(storedLayout.origins.isEmpty)
        let desks = await store.desks
        XCTAssertTrue(desks.isEmpty)

        try await learn(layout(["A", "B"]), into: store)
        let named = await store.desks.map(\.name)
        XCTAssertEqual(named, ["Desk 1"])
    }

    // MARK: Forget holds

    func testForgottenDeskIsNotSilentlyRegisteredByTheNextLearn() async throws {
        let store = LearnedLayoutStore()
        let docked = layout(["A", "B"])
        try await learn(docked, into: store)
        let key = try XCTUnwrap(DeskKey.make(for: docked))
        let forgot = await store.forget(deskKey: key)
        XCTAssertTrue(forgot)

        try await learn(docked, into: store)
        let afterLearn = await store.desks
        XCTAssertTrue(afterLearn.isEmpty)
        let announce = await store.consumeForgotten(for: docked)
        XCTAssertTrue(announce)
        let again = await store.consumeForgotten(for: docked)
        XCTAssertFalse(again, "announced once")
    }

    func testSnapshotSavedWhileForgetIsPruningDoesNotResurrectTheDesk() async throws {
        let docked = layout(["A", "B"])
        let box = StoreBox()
        let announcedDuringPrune = FlagBox()
        let store = LearnedLayoutStore(snapshotPruner: { _ in
            // A scheduled snapshot lands after the prune started and before the in-memory removal.
            _ = await box.store?.learn(docked, ifGate: try XCTUnwrap(SnapshotGate().token()))
            let announce = await box.store?.consumeForgotten(for: docked) ?? false
            announcedDuringPrune.set(announce)
        })
        box.store = store
        try await learn(docked, into: store)
        let key = try XCTUnwrap(DeskKey.make(for: docked))
        let forgot = await store.forget(deskKey: key)
        XCTAssertTrue(forgot)
        XCTAssertFalse(announcedDuringPrune.value, "no announcement while the prune is in flight")
        let desks = await store.desks
        XCTAssertTrue(desks.isEmpty)
        let announce = await store.consumeForgotten(for: docked)
        XCTAssertTrue(announce, "the next snapshot after the forget completes announces it")
    }

    func testFailedPruneKeepsTheDeskRegistered() async throws {
        struct PruneFailure: Error {}
        let store = LearnedLayoutStore(snapshotPruner: { _ in throw PruneFailure() })
        let docked = layout(["A", "B"])
        try await learn(docked, into: store)
        let forgot = await store.forget(deskKey: try XCTUnwrap(DeskKey.make(for: docked)))
        XCTAssertFalse(forgot)
        try await learn(docked, into: store)
        let desks = await store.desks
        XCTAssertEqual(desks.count, 1)
        let announce = await store.consumeForgotten(for: docked)
        XCTAssertFalse(announce)
    }
}

private final class StoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LearnedLayoutStore?
    var store: LearnedLayoutStore? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ newValue: Bool) { lock.lock(); flag = newValue; lock.unlock() }
}
