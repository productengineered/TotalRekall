import XCTest
@testable import TotalRekall

final class RestoreResultSummaryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func result(_ status: RestoreStatus, wid: UInt32 = 1) -> RestoreWindowResult {
        RestoreWindowResult(snapshotID: UUID(), windowID: wid, bundleID: "com.example", appName: "App",
                            title: "t", status: status)
    }

    private func summary(_ statuses: [RestoreStatus]) -> RestoreSummary {
        RestoreSummary(results: statuses.map { result($0) }, date: date)
    }

    func testAllRestoredIsCleanAndMenuLine() {
        let s = summary([.moved, .spaceMoved, .alreadyCorrect])
        XCTAssertEqual(s.restored, 3)
        XCTAssertEqual(s.total, 3)
        XCTAssertFalse(s.needsAttention)
        XCTAssertEqual(s.menuLine(timeZone: TimeZone(identifier: "UTC")!), "Last restore: 3 of 3 windows, 10:13 PM")
        XCTAssertEqual(s.asRestoreResult(), .windows(restored: 3, total: 3, date: date))
    }

    func testIntentionalSkipsExcludedFromTotal() {
        let s = summary([.moved, .skipped(.minimized), .skipped(.fullscreen), .skipped(.sticky)])
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.restored, 1)
        XCTAssertEqual(s.intentionallySkipped, 3)
        XCTAssertFalse(s.needsAttention)
    }

    func testDesktopMissingAndNotFoundCountAgainstTotalAndFlagPartial() {
        let s = summary([.moved, .skipped(.desktopMissing), .skipped(.notFound), .skipped(.panelNotConnected)])
        XCTAssertEqual(s.total, 4)
        XCTAssertEqual(s.restored, 1)
        XCTAssertEqual(s.desktopMissing, 1)
        XCTAssertTrue(s.isPartial)
        XCTAssertFalse(s.isFailed)
        XCTAssertTrue(s.needsAttention)
    }

    func testMovedUnverifiedCountsRestoredButIsPartial() {
        let s = summary([.moved, .movedUnverified])
        XCTAssertEqual(s.restored, 2)
        XCTAssertEqual(s.unverified, 1)
        XCTAssertTrue(s.isPartial)
        XCTAssertTrue(s.needsAttention)
    }

    func testAxUnreachableIsPartial() {
        let s = summary([.moved, .axUnreachable])
        XCTAssertEqual(s.unreachable, 1)
        XCTAssertEqual(s.restored, 1)
        XCTAssertTrue(s.isPartial)
    }

    func testNothingRestoredIsFailed() {
        let s = summary([.axUnreachable, .failed, .skipped(.desktopMissing)])
        XCTAssertTrue(s.isFailed)
        XCTAssertFalse(s.isPartial)
        XCTAssertTrue(s.needsAttention)
        XCTAssertEqual(s.failed, 1)
    }

    func testEmptyRestoreIsNotAFailure() {
        let s = summary([])
        XCTAssertFalse(s.isFailed)
        XCTAssertFalse(s.needsAttention)
        XCTAssertEqual(s.menuLine(timeZone: TimeZone(identifier: "UTC")!), "Last restore: 0 of 0 windows, 10:13 PM")
    }

    func testStatusLogValuesRoundTrip() throws {
        let all: [RestoreStatus] = [.moved, .movedUnverified, .axUnreachable, .spaceMoved, .alreadyCorrect, .failed,
                                    .skipped(.minimized), .skipped(.fullscreen), .skipped(.sticky),
                                    .skipped(.desktopMissing), .skipped(.panelNotConnected), .skipped(.notFound)]
        for status in all {
            XCTAssertEqual(RestoreStatus(logValue: status.logValue), status)
            let data = try JSONEncoder().encode([status])
            XCTAssertEqual(try JSONDecoder().decode([RestoreStatus].self, from: data), [status])
        }
        XCTAssertEqual(RestoreStatus.skipped(.desktopMissing).logValue, "skipped:desktop-missing")
        XCTAssertNil(RestoreStatus(logValue: "bogus"))
    }

    func testFromPlanOnlyMapsSkipsAndAlreadyCorrect() {
        func planned(_ a: PlannedAction) -> PlannedWindow {
            PlannedWindow(snapshotID: UUID(), windowID: 1, bundleID: "b", appName: "a", title: "t", action: a)
        }
        XCTAssertEqual(RestoreWindowResult.fromPlanOnly(planned(.alreadyCorrect))?.status, .alreadyCorrect)
        XCTAssertEqual(RestoreWindowResult.fromPlanOnly(planned(.skip(.sticky)))?.status, .skipped(.sticky))
        XCTAssertNil(RestoreWindowResult.fromPlanOnly(planned(.frameFix(SnapshotFrame(x: 0, y: 0, width: 1, height: 1)))))
    }

    // MARK: Attention rule (bug 33)

    /// Attention only when the layout is likely wrong. Parameterized over the real UAT mix
    /// (restore-log 2026-11-06 08:03) and each condition that must still raise the icon.
    func testAttentionOnlyWhenLayoutIsLikelyWrong() {
        let uatMix: [RestoreStatus] = Array(repeating: .alreadyCorrect, count: 17)
            + Array(repeating: .skipped(.minimized), count: 22)
            + [.skipped(.notFound), .axUnreachable]
        struct Case {
            let name: String
            let statuses: [RestoreStatus]
            let fix: FixOutcome?
            let attention: Bool
            init(_ name: String, _ statuses: [RestoreStatus], _ fix: FixOutcome?, _ attention: Bool) {
                (self.name, self.statuses, self.fix, self.attention) = (name, statuses, fix, attention)
            }
        }
        let cases: [Case] = [
            Case("UAT 08:03 mix: 1 not-found + 1 ax-unreachable", uatMix, .skipped(reason: "no swap"), false),
            Case("single ax-unreachable", [.moved, .axUnreachable], nil, false),
            Case("single not-found", [.alreadyCorrect, .skipped(.notFound)], nil, false),
            Case("panel not connected", [.moved, .skipped(.panelNotConnected)], nil, false),
            Case("clean with verified fix", [.moved, .spaceMoved], .verified, false),
            Case("clean with already-in-order monitors", [.alreadyCorrect], .alreadyInOrder, false),
            Case("moved-unverified", [.moved, .movedUnverified], nil, true),
            Case("failed Space move", [.moved, .failed], nil, true),
            Case("desktop missing", [.moved, .skipped(.desktopMissing)], nil, true),
            Case("monitor fix failed", [.moved], .failed(reason: "apply"), true),
            Case("monitor fix unverified", [.alreadyCorrect], .unverified(reason: "readback"), true),
            Case("UAT mix plus a failed move", uatMix + [.failed], nil, true)
        ]
        for c in cases {
            let s = RestoreSummary(results: c.statuses.map { result($0) }, date: date, monitorFix: c.fix)
            XCTAssertEqual(s.needsAttention, c.attention, c.name)
        }
    }

    func testUnreachableAndNotFoundStayVisibleInDetailAndLog() {
        let statuses: [RestoreStatus] = [.alreadyCorrect, .skipped(.notFound), .axUnreachable]
        let s = RestoreSummary(results: statuses.map { result($0) }, date: date)
        XCTAssertEqual(s.leftInPlace, 2)
        XCTAssertEqual(s.unreachable, 1)
        XCTAssertEqual(s.menuLine(timeZone: TimeZone(identifier: "UTC")!), "Last restore: 1 of 3 windows, 10:13 PM")
        let log = RestoreLog(results: statuses.map { result($0) }, date: date, configKey: nil,
                             capability: .full, layout: nil, monitorFix: .verified)
        XCTAssertFalse(log.needsAttention)
        XCTAssertEqual(log.counts.unreachable, 1)
        XCTAssertEqual(log.monitorFix, "verified")
        XCTAssertEqual(log.windows.map(\.status), statuses)
    }

    func testLogWithoutMonitorFixKeyStillDecodes() throws {
        let log = RestoreLog(results: [result(.moved)], date: date, configKey: nil, capability: .full, layout: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        json.removeValue(forKey: "monitorFix")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(RestoreLog.self, from: data).monitorFix)
    }

    // MARK: RestoreLogStore

    func testLogStoreWritesAndReadsBack() throws {
        let store = RestoreLogStore(directory: dir)
        XCTAssertFalse(store.hasLog)
        let layout = MonitorLayout(origins: ["builtin": .init(x: 0, y: 0), "EXT1": .init(x: 1728, y: -200)])
        let log = RestoreLog(results: [result(.moved), result(.skipped(.desktopMissing), wid: 2)], date: date,
                             configKey: "cfg", capability: .positionOnly(reason: "no symbol"), layout: layout)
        try store.write(log)
        XCTAssertTrue(store.hasLog)
        XCTAssertEqual(store.logURL.lastPathComponent, "restore-log.json")
        let loaded = try store.load()
        XCTAssertEqual(loaded, log)
        XCTAssertEqual(loaded.capability, "positionOnly: no symbol")
        XCTAssertEqual(loaded.layout["EXT1"], RestoreLogOrigin(x: 1728, y: -200))
        XCTAssertEqual(loaded.counts.total, 2)
        XCTAssertEqual(loaded.counts.desktopMissing, 1)
        XCTAssertTrue(loaded.needsAttention)
    }

    func testLogStoreWritesPrivatePermissions() throws {
        let store = RestoreLogStore(directory: dir)
        let log = RestoreLog(results: [result(.moved)], date: date, configKey: "cfg",
                             capability: .full, layout: MonitorLayout(origins: [:]))
        try store.write(log)
        try store.write(log)
        let fm = FileManager.default
        let fileMode = try fm.attributesOfItem(atPath: store.logURL.path)[.posixPermissions] as? Int
        let dirMode = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
    }

    func testLogStoreOverwriteLeavesNoTempFiles() throws {
        let store = RestoreLogStore(directory: dir)
        for n in 0..<3 {
            let log = RestoreLog(results: [result(.moved, wid: UInt32(n))], date: date, configKey: nil,
                                 capability: .full, layout: nil)
            try store.write(log)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files, ["restore-log.json"])
        XCTAssertEqual(try store.load().windows.first?.windowID, 2)
    }

    func testLogStoreLoadFailsOnCorruptFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RestoreLogStore(directory: dir)
        try Data("not json".utf8).write(to: store.logURL)
        XCTAssertThrowsError(try store.load())
    }
}

// MARK: - Quiet wake policy

extension RestoreResultSummaryTests {
    private static let own = "com.productengineered.TotalRekall"

    /// One saved user window plus the matching result per status; `extraOwn` adds Total Rekall's own.
    private func quietInput(
        trigger: CycleTrigger = .wake,
        eligibility: QuietWakeEligibility? = QuietWakeEligibility(displaysAddedOrRemoved: false,
                                                                  resumedByHoldBound: false),
        fix: FixOutcome = .alreadyInOrder,
        statuses: [RestoreStatus] = [.alreadyCorrect, .alreadyCorrect],
        dropResult: Bool = false,
        snapshotBundle: String = "com.example",
        emptySnapshot: Bool = false
    ) -> QuietWakePolicy.Input {
        let ids = statuses.map { _ in UUID() }
        let snapshot = emptySnapshot ? [] : ids.map { QuietWakePolicy.SnapshotWindow(id: $0, bundleID: snapshotBundle) }
            + [QuietWakePolicy.SnapshotWindow(id: UUID(), bundleID: Self.own)]
        var results = zip(ids, statuses).map { id, status in
            RestoreWindowResult(snapshotID: id, windowID: 1, bundleID: snapshotBundle, appName: "App",
                                title: "t", status: status)
        }
        if dropResult { results.removeLast() }
        return QuietWakePolicy.Input(trigger: trigger, eligibility: eligibility, fix: fix,
                                     snapshotWindows: snapshot, ownBundleID: Self.own, results: results)
    }

    /// AC2/AC3/AC8: quiet rows are the baseline, each quiet-compatible skip, and the 28ABACCA
    /// regression; every other row (one per disqualifier) must be non-quiet.
    func testQuietWakePolicyTable() {
        let quietSkips: [RestoreSkipReason] = [.minimized, .fullscreen, .sticky, .notFound]
        let badSkips: [RestoreSkipReason] = [.desktopMissing, .panelNotConnected, .untitledNoAXMatch]
        let badStatuses: [RestoreStatus] = [.moved, .movedUnverified, .spaceMoved, .axUnreachable, .failed]
            + badSkips.map { .skipped($0) }
        var rows: [(String, QuietWakePolicy.Input, Bool)] = [("all already-correct", quietInput(), true)]
        for reason in quietSkips {
            rows.append(("quiet skip \(reason)", quietInput(statuses: [.alreadyCorrect, .skipped(reason)]), true))
        }
        // Mirrors real wake cycle 28ABACCA: 20 already-correct, 20 minimized, 1 closed since the snapshot.
        let cycle28ABACCA: [RestoreStatus] = Array(repeating: .alreadyCorrect, count: 20)
            + Array(repeating: .skipped(.minimized), count: 20) + [.skipped(.notFound)]
        rows.append(("cycle 28ABACCA", quietInput(statuses: cycle28ABACCA), true))
        rows.append(("all skipped, none verified",
                     quietInput(statuses: [.skipped(.minimized), .skipped(.notFound)]), false))
        for status in badStatuses {
            rows.append(("status \(status.logValue)", quietInput(statuses: [.alreadyCorrect, status]), false))
        }
        rows += [
            ("missing result", quietInput(dropResult: true), false),
            ("own-window-only snapshot", quietInput(snapshotBundle: Self.own), false),
            ("empty snapshot", quietInput(emptySnapshot: true), false),
            ("no results", quietInput(statuses: []), false),
            ("display added or removed",
             quietInput(eligibility: QuietWakeEligibility(displaysAddedOrRemoved: true, resumedByHoldBound: false)),
             false),
            ("hold-bound resume",
             quietInput(eligibility: QuietWakeEligibility(displaysAddedOrRemoved: false, resumedByHoldBound: true)),
             false),
            ("no eligibility (context from before quiet wake)", quietInput(eligibility: nil), false)
        ]
        let fixes: [FixOutcome] = [.verified, .unverified(reason: "x"), .skipped(reason: "x"), .failed(reason: "x")]
        rows += fixes.map { ("fix \($0)", quietInput(fix: $0), false) }
        rows += CycleTrigger.allCases.filter { $0 != .wake }.map { ("trigger \($0)", quietInput(trigger: $0), false) }

        XCTAssertEqual(rows.filter(\.2).count, 1 + quietSkips.count + 1, "quiet rows: baseline, skips, regression")
        for (name, input, expected) in rows {
            XCTAssertEqual(QuietWakePolicy.isQuiet(input), expected, name)
        }
    }

    /// Contexts written before quiet wake existed have no quietWake key and still decode (as never quiet).
    func testCycleContextDecodesWithoutQuietWakeKey() throws {
        let json = #"{"trigger":"wake","cycleID":"\#(UUID().uuidString)","startedAt":0}"#
        let context = try JSONDecoder().decode(CycleContext.self, from: Data(json.utf8))
        XCTAssertEqual(context.trigger, .wake)
        XCTAssertNil(context.quietWake)
    }
}
