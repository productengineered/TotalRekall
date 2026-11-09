import XCTest
@testable import TotalRekall

final class RestoreDetailFormatterTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        cal.locale = locale
        return cal
    }

    private func window(_ app: String, _ status: RestoreStatus, bundle: String = "com.example.app") -> RestoreWindowResult {
        RestoreWindowResult(snapshotID: UUID(), windowID: 1, bundleID: bundle, appName: app,
                            title: "SECRET TITLE", status: status)
    }

    private func lines(_ windows: [RestoreWindowResult]) -> [String] {
        RestoreDetailFormatter.appLines(from: windows)
    }

    func testEveryStatusMapsToPlainLanguage() {
        let cases: [(RestoreStatus, String)] = [
            (.moved, "A — 1 restored"),
            (.spaceMoved, "A — 1 restored"),
            (.alreadyCorrect, "A — 1 restored"),
            (.movedUnverified, "A — 1 couldn't verify position"),
            (.failed, "A — 1 couldn't move to its desktop"),
            (.skipped(.desktopMissing), "A — 1 desktop no longer exists"),
            (.axUnreachable, "A — 1 left in place (couldn't reach)"),
            (.skipped(.notFound), "A — 1 left in place (window not found)"),
            (.skipped(.panelNotConnected), "A — 1 left in place (monitor not connected)"),
            (.skipped(.untitledNoAXMatch), "A — 1 skipped (helper window)"),
            (.skipped(.minimized), "A — 1 skipped (minimized)"),
            (.skipped(.fullscreen), "A — 1 skipped (full screen)"),
            (.skipped(.sticky), "A — 1 skipped (on all desktops)")
        ]
        for (status, expected) in cases {
            XCTAssertEqual(lines([window("A", status)]), [expected], "\(status)")
        }
    }

    func testGroupsByAppAndJoinsPartsInFixedOrder() {
        let windows = [
            window("Safari", .movedUnverified), window("Safari", .moved), window("Safari", .alreadyCorrect),
            window("Chrome", .moved), window("Chrome", .moved), window("Chrome", .spaceMoved),
            window("Terminal", .axUnreachable), window("Terminal", .axUnreachable)
        ]
        XCTAssertEqual(lines(windows), [
            "Safari — 2 restored, 1 couldn't verify position",
            "Terminal — 2 left in place (couldn't reach)",
            "Chrome — 3 restored"
        ])
    }

    func testSortsProblemsFirstThenAlphabeticalCaseInsensitive() {
        let windows = [
            window("zeta", .moved), window("Alpha", .moved),
            window("Mail", .skipped(.minimized)),
            window("Notes", .axUnreachable),
            window("Finder", .failed), window("bear", .movedUnverified)
        ]
        let names = lines(windows).map { $0.components(separatedBy: " — ")[0] }
        XCTAssertEqual(names, ["bear", "Finder", "Notes", "Alpha", "zeta", "Mail"])
    }

    func testFallsBackToBundleIDWhenAppNameEmpty() {
        XCTAssertEqual(lines([window("", .moved, bundle: "com.example.helper")]),
                       ["com.example.helper — 1 restored"])
    }

    func testWindowTitlesNeverAppear() {
        let all = lines([window("A", .moved), window("B", .failed)]).joined()
        XCTAssertFalse(all.contains("SECRET TITLE"))
    }

    func testMonitorLineMatchesFixOutcomeByPrefix() {
        let cases: [(String?, String?)] = [
            (String(describing: FixOutcome.verified), "Monitors: fixed"),
            (String(describing: FixOutcome.alreadyInOrder), "Monitors: already in order"),
            (String(describing: FixOutcome.skipped(reason: "ok")), "Monitors: already in order"),
            (String(describing: FixOutcome.unverified(reason: "x")), "Monitors: fix not verified"),
            (String(describing: FixOutcome.failed(reason: "x")), "Monitors: couldn't fix"),
            (nil, nil),
            ("something else", nil)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(RestoreDetailFormatter.monitorLine(from: raw), expected, "\(raw ?? "nil")")
        }
    }

    func testTriggerLineAndTodayVersusEarlierDate() {
        let now = Date(timeIntervalSince1970: 1_793_900_100)  // 2026-11-05 ... pinned below
        let today = now.addingTimeInterval(-3600)
        let earlier = now.addingTimeInterval(-3 * 86_400)
        let cal = calendar
        let todayStamp = RestoreDetailFormatter.timestamp(today, now: now, calendar: cal, locale: locale)
        let earlierStamp = RestoreDetailFormatter.timestamp(earlier, now: now, calendar: cal, locale: locale)
        XCTAssertEqual(todayStamp, today.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                                     locale: locale, calendar: cal, timeZone: cal.timeZone)))
        XCTAssertEqual(earlierStamp, earlier.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                                         locale: locale, calendar: cal, timeZone: cal.timeZone)))
        XCTAssertNotEqual(todayStamp, earlierStamp)
        XCTAssertTrue(earlierStamp.count > todayStamp.count, "an earlier restore shows the date as well")

        let triggers: [(CycleTrigger?, String)] = [
            (.displayChange, "After a display change"), (.wake, "Restored after wake"),
            (.launch, "At launch"), (.manual, "You chose Restore Now"), (nil, "Restored")
        ]
        for (trigger, lead) in triggers {
            XCTAssertEqual(RestoreDetailFormatter.triggerLine(trigger: trigger, date: today, now: now,
                                                              calendar: cal, locale: locale),
                           "\(lead) · \(todayStamp)")
        }
    }

    func testTimestampRelativeDayCases() {
        let cal = calendar
        func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
        }
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                         calendar: cal, timeZone: cal.timeZone)
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                         calendar: cal, timeZone: cal.timeZone)
        struct Case {
            let name: String
            let date: Date
            let now: Date
            let yesterday: Bool
            let timeOnly: Bool
        }
        let cases = [
            Case(name: "today", date: utc(2026, 11, 8, 9, 0),
                 now: utc(2026, 11, 8, 15, 0),
                 yesterday: false, timeOnly: true),
            Case(name: "yesterday", date: utc(2026, 11, 7, 20, 27),
                 now: utc(2026, 11, 8, 15, 0),
                 yesterday: true, timeOnly: false),
            Case(name: "two days ago", date: utc(2026, 11, 6, 20, 27),
                 now: utc(2026, 11, 8, 15, 0),
                 yesterday: false, timeOnly: false),
            Case(name: "across midnight", date: utc(2026, 11, 7, 23, 59),
                 now: utc(2026, 11, 8, 0, 1),
                 yesterday: true, timeOnly: false),
            Case(name: "month boundary", date: utc(2026, 10, 31, 20, 27),
                 now: utc(2026, 11, 1, 9, 0),
                 yesterday: true, timeOnly: false)
        ]
        for testCase in cases {
            let (name, date, now, yesterday, timeOnly) = (testCase.name, testCase.date, testCase.now,
                                                          testCase.yesterday, testCase.timeOnly)
            let stamp = RestoreDetailFormatter.timestamp(date, now: now, calendar: cal, locale: locale)
            if yesterday {
                XCTAssertEqual(stamp, "Yesterday at \(date.formatted(timeStyle))", name)
            } else if timeOnly {
                XCTAssertEqual(stamp, date.formatted(timeStyle), name)
            } else {
                XCTAssertEqual(stamp, date.formatted(dateStyle), name)
            }
        }
    }

    func testWakeLeadWithYesterdayTimestamp() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 0)) ?? .distantPast
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 20, minute: 27)) ?? .distantPast
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                         calendar: cal, timeZone: cal.timeZone)
        XCTAssertEqual(RestoreDetailFormatter.triggerLine(trigger: .wake, date: date, now: now,
                                                          calendar: cal, locale: locale),
                       "Restored after wake · Yesterday at \(date.formatted(timeStyle))")
    }

    func testDetailFromEighteenAppLogCapsAtFifteenWithOverflow() {
        let windows = (1...18).map { window(String(format: "App %02d", $0), .moved) }
        let log = RestoreLog(results: windows, date: Date(), configKey: nil, capability: .full, layout: nil,
                             monitorFix: .verified, context: CycleContext(trigger: .wake))
        let detail = RestoreDetailFormatter.detail(from: log)
        XCTAssertEqual(detail.appLines.count, 15)
        XCTAssertEqual(detail.overflowCount, 3)
        XCTAssertEqual(detail.trigger, .wake)
        XCTAssertEqual(detail.monitorLine, "Monitors: fixed")
        XCTAssertEqual(detail.restoredCount, 18)
        XCTAssertEqual(detail.totalCount, 18)
    }

    func testLoaderReportsNoneLoadedAndUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestoreLogStore(directory: dir)
        let loader = RestoreLogDetailLoader(store: store)
        let none = await loader.load()
        XCTAssertEqual(none, .none)

        try store.write(RestoreLog(results: [window("A", .moved)], date: Date(), configKey: nil,
                                   capability: .full, layout: nil))
        guard case .loaded(let detail) = await loader.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(detail.appLines, ["A — 1 restored"])

        try Data("{ not json".utf8).write(to: store.logURL)
        let bad = await loader.load()
        XCTAssertEqual(bad, .unreadable)
    }
}

final class FixOutcomeAttentionTests: XCTestCase {
    func testSetsAttentionIsExhaustivePerOutcome() {
        let cases: [(FixOutcome, Bool)] = [
            (.verified, false), (.alreadyInOrder, false),
            (.unverified(reason: "x"), true), (.skipped(reason: "x"), true), (.failed(reason: "x"), true)
        ]
        for (fix, expected) in cases {
            XCTAssertEqual(fix.setsAttention, expected, "\(fix)")
            XCTAssertEqual(RestoreOutcome.monitorsFixed(fix, date: Date()).setsAttention, expected, "\(fix)")
        }
    }

    func testAlreadyInOrderRawStringHasUniquePrefix() {
        let raw = String(describing: FixOutcome.alreadyInOrder)
        XCTAssertEqual(raw, "alreadyInOrder")
        for other in ["verified", "unverified", "skipped", "failed"] { XCTAssertFalse(raw.hasPrefix(other)) }
    }
}
