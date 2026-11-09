import XCTest
@testable import TotalRekall

final class SnapshotStoreTests: XCTestCase {
    private var dir: URL!
    private let key = SnapshotKey.make(panelSerials: ["A1", "B2"])

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func window(_ n: Int) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.example.app\(n)", appName: "App \(n)", windowID: UInt32(100 + n),
            windowTitle: "w\(n)", windowIndex: n, displayFingerprint: nil, displayIndex: 0,
            panelSerial: "A1", spaceOrdinal: 1, spaceUUID: nil, spaceIndex: 0,
            frame: SnapshotFrame(x: 0, y: 0, width: 800, height: 600),
            isFullscreen: false, isMinimized: false, zOrder: n)
    }

    /// `at` = seconds after the base capture time (for the shrink-confirmation interval).
    private func config(windows: Int, at offset: TimeInterval = 0) -> DisplayConfigSnapshot {
        DisplayConfigSnapshot(
            fingerprint: key, displayConfigName: "2 displays",
            displays: [DisplaySnapshot(
                vendorID: 1, productID: 2, serialNumber: "", panelSerial: "A1", unitNumber: 0,
                iokitLocationPath: nil, resolution: SnapshotSize(width: 1728, height: 1117),
                scaleFactor: 2, displayName: "Built-in", originX: 0, originY: 0, isMain: true, cgDisplayID: nil)],
            lastSnapshotDate: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            windows: (0..<windows).map(window))
    }

    func testSaveEnforcesConfigurationCapByEvictingOldest() async throws {
        let store = SnapshotStore(directory: dir)
        func cfg(_ n: Int) -> DisplayConfigSnapshot {
            var c = config(windows: 1)
            c.lastSnapshotDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
            return c
        }
        for n in 0..<SnapshotStore.maxConfigurations { _ = try await store.save(cfg(n), key: "k\(n)") }
        _ = try await store.save(cfg(1000), key: "newest")
        let file = try await store.load()
        XCTAssertEqual(file.configurations.count, SnapshotStore.maxConfigurations)
        XCTAssertNotNil(file.configurations["newest"])
        XCTAssertNil(file.configurations["k0"], "oldest by lastSnapshotDate is evicted")
        XCTAssertNotNil(file.configurations["k1"])
        let again = try await store.load()
        XCTAssertEqual(again.configurations.count, SnapshotStore.maxConfigurations, "store was not archived/reset")
    }

    func testZeroWindowCaptureSkippedAndFileUnchanged() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 10), key: key)
        let before = try Data(contentsOf: store.snapshotURL)
        let outcome = try await store.save(config(windows: 0), key: key)
        XCTAssertEqual(outcome, .skippedZeroWindows(priorCount: 10))
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), before)
    }

    func testZeroWindowsWithNoPriorIsWritten() async throws {
        let store = SnapshotStore(directory: dir)
        let outcome = try await store.save(config(windows: 0), key: key)
        XCTAssertEqual(outcome, .written)
    }

    func testWriteFailureLeavesPreviousFileIntact() async throws {
        let good = SnapshotStore(directory: dir)
        _ = try await good.save(config(windows: 10), key: key)
        let before = try Data(contentsOf: good.snapshotURL)

        struct Boom: Error {}
        let failing = SnapshotStore(directory: dir, tempWriter: { _, _ in throw Boom() })
        do {
            _ = try await failing.save(config(windows: 12), key: key)
            XCTFail("expected write failure")
        } catch let error as SnapshotStoreError {
            guard case .writeFailed = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: good.snapshotURL), before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    /// Bug 65 (FR-19): an under-half shrink is held on first sight and committed only by a second
    /// agreeing capture one interval later; then the prior file is kept as last-good.
    func testUnderHalfShrinkIsHeldThenCommittedOnConfirmationKeepingPriorAsLastGood() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 10), key: key)
        let prior = try Data(contentsOf: store.snapshotURL)
        let first = try await store.save(config(windows: 4), key: key)
        XCTAssertEqual(first, .heldUnconfirmedShrink(priorCount: 10, newCount: 4))
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), prior)
        let outcome = try await store.save(config(windows: 4, at: 600), key: key)
        XCTAssertEqual(outcome, .writtenKeepingLastGood(priorCount: 10, newCount: 4))
        XCTAssertEqual(try Data(contentsOf: store.lastGoodURL), prior)
        let current = try await store.load()
        XCTAssertEqual(current.configurations[key]?.windows.count, 4)
    }

    func testExactlyHalfIsNotSuspect() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 10), key: key)
        let outcome = try await store.save(config(windows: 5), key: key)
        XCTAssertEqual(outcome, .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lastGoodURL.path))
    }

    func testClearConfigBypassesGuardAndPreservesLastGood() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 6), key: key)
        try await store.clearConfig(key: key)
        let current = try await store.load()
        XCTAssertEqual(current.configurations[key]?.windows.count, 0)
        let lastGood = try await store.loadLastGood()
        XCTAssertEqual(lastGood?.configurations[key]?.windows.count, 6)
    }

    func testCorruptFileIsArchivedAndFreshReturned() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SnapshotStore(directory: dir)
        try Data("not json".utf8).write(to: store.snapshotURL)
        let file = try await store.load()
        XCTAssertTrue(file.configurations.isEmpty)
        let info = await store.corruptRecoveryInfo
        XCTAssertNotNil(info)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    func testMissingFileLoadsEmpty() async throws {
        let store = SnapshotStore(directory: dir)
        let file = try await store.load()
        XCTAssertTrue(file.configurations.isEmpty)
    }

    // MARK: - SnapshotGate commit

    private func leftoverTemps() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
    }

    func testOpenGateTokenCommits() async throws {
        let gate = SnapshotGate()
        let store = SnapshotStore(directory: dir)
        let token = try XCTUnwrap(gate.token())
        let outcome = try await store.save(config(windows: 3), key: key, ifGate: token)
        XCTAssertEqual(outcome, .written)
        let file = try await store.load()
        XCTAssertEqual(file.configurations[key]?.windows.count, 3)
    }

    func testGateClosedAfterTokenDiscardsWriteAndLeavesFileUntouched() async throws {
        let gate = SnapshotGate()
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 10), key: key)
        let before = try Data(contentsOf: store.snapshotURL)

        let token = try XCTUnwrap(gate.token())
        gate.closeForDisplayChange()
        let outcome = try await store.save(config(windows: 12), key: key, ifGate: token)
        XCTAssertEqual(outcome, .discardedGateClosed)
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), before)
        XCTAssertTrue(try leftoverTemps().isEmpty)
    }

    /// The callback lands while the store is staging its temp files (mid-write): nothing is renamed
    /// into place, including the last-good copy, and the staged temps are removed.
    func testCallbackDuringStagingDiscardsSnapshotAndLastGood() async throws {
        let gate = SnapshotGate()
        _ = try await SnapshotStore(directory: dir).save(config(windows: 10), key: key)
        let before = try Data(contentsOf: SnapshotStore(directory: dir).snapshotURL)

        let closing = SnapshotStore(directory: dir, tempWriter: { data, url in
            gate.closeForDisplayChange()  // a display callback arrives during the write
            try SnapshotStore.durableWrite(data, url)
        })
        let token = try XCTUnwrap(gate.token())
        // 10 -> 2 windows is a shrink (accepted, as a manual save would), so last-good is staged too.
        let outcome = try await closing.save(config(windows: 2), key: key, ifGate: token, acceptShrink: true)
        XCTAssertEqual(outcome, .discardedGateClosed)
        XCTAssertEqual(try Data(contentsOf: closing.snapshotURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: closing.lastGoodURL.path))
        XCTAssertTrue(try leftoverTemps().isEmpty)
    }

    func testTokenFromEarlierEpochIsDiscardedEvenAfterReopen() async throws {
        let gate = SnapshotGate()
        let store = SnapshotStore(directory: dir)
        let token = try XCTUnwrap(gate.token())
        let epoch = gate.closeForDisplayChange()
        XCTAssertTrue(gate.reopen(ifEpoch: epoch))
        let outcome = try await store.save(config(windows: 3), key: key, ifGate: token)
        XCTAssertEqual(outcome, .discardedGateClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    // MARK: - Shrink confirmation (Bug 65)

    /// The incident's sequence 42 -> 1 -> 1 -> 1 inside one interval: the restore source stays 42.
    func testRepeatedDropWithinOneIntervalNeverReplacesTheRestoreSource() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key)
        for offset in [10.0, 120, 400] {
            let outcome = try await store.save(config(windows: 1, at: offset), key: key)
            XCTAssertEqual(outcome, .heldUnconfirmedShrink(priorCount: 42, newCount: 1))
        }
        let restoreSource = try await store.load()
        XCTAssertEqual(restoreSource.configurations[key]?.windows.count, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lastGoodURL.path))
    }

    /// Early repeats keep the first capture's time, so confirmation is one interval after the FIRST.
    func testEarlyAgreeingRepeatDoesNotPushConfirmationBack() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key)
        _ = try await store.save(config(windows: 10), key: key)
        _ = try await store.save(config(windows: 11, at: 300), key: key)
        let outcome = try await store.save(config(windows: 10, at: 600), key: key)
        XCTAssertEqual(outcome, .writtenKeepingLastGood(priorCount: 42, newCount: 10))
    }

    func testDisagreeingShrinkRestartsConfirmation() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key)
        _ = try await store.save(config(windows: 1), key: key)
        let other = try await store.save(config(windows: 15, at: 600), key: key)
        XCTAssertEqual(other, .heldUnconfirmedShrink(priorCount: 42, newCount: 15), "1 vs 15 do not agree")
        let confirmed = try await store.save(config(windows: 15, at: 1200), key: key)
        XCTAssertEqual(confirmed, .writtenKeepingLastGood(priorCount: 42, newCount: 15))
    }

    func testNormalCaptureClearsAPendingShrink() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key)
        _ = try await store.save(config(windows: 5), key: key)
        let normal = try await store.save(config(windows: 40, at: 300), key: key)
        XCTAssertEqual(normal, .written)
        let again = try await store.save(config(windows: 5, at: 900), key: key)
        XCTAssertEqual(again, .heldUnconfirmedShrink(priorCount: 40, newCount: 5), "the earlier pending was dropped")
    }

    /// Save Snapshot Now is user intent: the shrink is committed at once and the prior kept as last-good.
    func testAcceptShrinkCommitsImmediately() async throws {
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key)
        let prior = try Data(contentsOf: store.snapshotURL)
        let outcome = try await store.save(config(windows: 3), key: key, acceptShrink: true)
        XCTAssertEqual(outcome, .writtenKeepingLastGood(priorCount: 42, newCount: 3))
        XCTAssertEqual(try Data(contentsOf: store.lastGoodURL), prior)
        let current = try await store.load()
        XCTAssertEqual(current.configurations[key]?.windows.count, 3)
    }

    func testShrinkCountsAgreeTolerance() {
        let cases: [(Int, Int, Bool)] = [(1, 1, true), (1, 2, true), (10, 11, true), (10, 13, false),
                                         (40, 44, true), (40, 46, false), (1, 15, false)]
        for (lhs, rhs, expected) in cases {
            XCTAssertEqual(SnapshotStore.shrinkCountsAgree(lhs, rhs), expected, "\(lhs) vs \(rhs)")
        }
    }
}

// MARK: - Pending shrink across a hold (Bug 65 review advisory 3)

extension SnapshotStoreTests {
    /// A shrink seen before a hold is never confirmed by a capture after it: the hold moves the gate
    /// epoch, so the next agreeing capture is a new first sighting and one more interval is needed.
    func testPendingShrinkSeenBeforeAHoldIsNotConfirmedAfterIt() async throws {
        let gate = SnapshotGate()
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 42), key: key, ifGate: try XCTUnwrap(gate.token()))
        let trusted = try Data(contentsOf: store.snapshotURL)

        let before = try await store.save(config(windows: 3), key: key, ifGate: try XCTUnwrap(gate.token()))
        XCTAssertEqual(before, .heldUnconfirmedShrink(priorCount: 42, newCount: 3))

        XCTAssertTrue(gate.setHold(.screensAsleep))
        XCTAssertTrue(gate.clearHold(.screensAsleep))

        let afterHold = try await store.save(config(windows: 3, at: 36_000), key: key,
                                             ifGate: try XCTUnwrap(gate.token()))
        XCTAssertEqual(afterHold, .heldUnconfirmedShrink(priorCount: 42, newCount: 3),
                       "first capture after the hold is a new first sighting, not a confirmation")
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), trusted)

        let confirmed = try await store.save(config(windows: 3, at: 36_600), key: key,
                                             ifGate: try XCTUnwrap(gate.token()))
        XCTAssertEqual(confirmed, .writtenKeepingLastGood(priorCount: 42, newCount: 3))
        let current = try await store.load()
        XCTAssertEqual(current.configurations[key]?.windows.count, 3)
    }

    /// A discarded save (gate closed before commit) also drops the pending shrink.
    func testDiscardedSaveDropsThePendingShrink() async throws {
        let gate = SnapshotGate()
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config(windows: 10), key: key)
        _ = try await store.save(config(windows: 2), key: key)  // pending, no token

        let stale = try XCTUnwrap(gate.token())
        _ = gate.closeForDisplayChange()
        let discarded = try await store.save(config(windows: 2, at: 300), key: key, ifGate: stale)
        XCTAssertEqual(discarded, .discardedGateClosed)

        let next = try await store.save(config(windows: 2, at: 600), key: key)
        XCTAssertEqual(next, .heldUnconfirmedShrink(priorCount: 10, newCount: 2))
    }
}
