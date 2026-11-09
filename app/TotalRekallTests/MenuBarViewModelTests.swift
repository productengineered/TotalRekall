import XCTest
@testable import TotalRekall

@MainActor
final class MenuBarViewModelTests: XCTestCase {
    private final class FakeActions: SnapshotActions, RestoreActions, RestoreLogProviding {
        var saves = 0
        var restores = 0
        var fixes = 0
        var hasLog = false
        var logURL: URL?
        func saveNow() async { saves += 1 }
        func restoreNow() async { restores += 1 }
        func fixMonitors() async { fixes += 1 }
    }

    private var fake: FakeActions!
    private var sut: MenuBarViewModel!

    override func setUp() {
        super.setUp()
        fake = FakeActions()
        sut = MenuBarViewModel(snapshotActions: fake, restoreActions: fake, logProvider: fake)
        sut.hasSnapshot = true
    }

    override func tearDown() {
        sut = nil
        fake = nil
        super.tearDown()
    }

    func testRestoreDisabledWhenNoSnapshot() {
        sut.hasSnapshot = false
        XCTAssertFalse(sut.isRestoreEnabled)
        XCTAssertTrue(sut.isSaveEnabled)
    }

    func testRevealLogDisabledWhenNoLog() {
        fake.hasLog = false
        XCTAssertFalse(sut.isRevealLogEnabled)
        XCTAssertNil(sut.restoreLogURLToReveal())
        fake.hasLog = true
        fake.logURL = URL(fileURLWithPath: "/tmp/restore.log")
        XCTAssertTrue(sut.isRevealLogEnabled)
        XCTAssertNotNil(sut.restoreLogURLToReveal())
    }

    func testWorkingDisablesSaveRestoreAndFixMonitors() {
        sut.state = .working
        XCTAssertFalse(sut.isSaveEnabled)
        XCTAssertFalse(sut.isRestoreEnabled)
        XCTAssertFalse(sut.isFixMonitorsEnabled)
        XCTAssertEqual(sut.statusLine, "Restoring windows…")
        XCTAssertTrue(sut.iconAnimates)
    }

    func testAttentionMapsToAttentionIcon() {
        sut.state = .attention
        XCTAssertEqual(sut.iconName, "exclamationmark.circle")
        XCTAssertEqual(sut.statusLine, "Needs attention — see Last restore")
        XCTAssertTrue(sut.isRestoreEnabled)
    }

    func testAccessibilityMissingDisablesActionsAndWarns() {
        sut.accessibilityGranted = false
        XCTAssertTrue(sut.showsAccessibilityWarning)
        XCTAssertFalse(sut.isSaveEnabled)
        XCTAssertFalse(sut.isRestoreEnabled)
        XCTAssertFalse(sut.isFixMonitorsEnabled)
        XCTAssertEqual(sut.iconName, "exclamationmark.triangle")
        XCTAssertEqual(sut.statusLine, "Accessibility access needed")
        XCTAssertNotEqual(sut.iconName, MenuBarViewModel().iconName)
    }

    func testIdleStatusLineWatchingAndAutoRestoreOff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(sut.iconName, "arrow.counterclockwise.circle")
        XCTAssertEqual(sut.statusText(now: now, locale: locale), "Watching your desk · no snapshot yet")
        sut.lastSnapshotDate = now.addingTimeInterval(-240)
        let age = MenuBarViewModel.relativeAge(of: now.addingTimeInterval(-240), now: now, locale: locale)
        XCTAssertEqual(sut.statusText(now: now, locale: locale), "Watching your desk · last snapshot \(age)")
        XCTAssertFalse(age.isEmpty)
        sut.lastSnapshotDate = now.addingTimeInterval(-20)
        XCTAssertEqual(sut.statusText(now: now, locale: locale), "Watching your desk · last snapshot just now")
        sut.autoRestoreEnabled = false
        XCTAssertEqual(sut.status, .autoRestoreOff)
        XCTAssertEqual(sut.statusText(now: now, locale: locale), "Auto-restore is off")
    }

    func testStatusPrecedenceAndPauseCopy() {
        let now = Date()
        let cases: [(SnapshotRefusal, MenuStatus, String)] = [
            (.displayChangeInProgress, .pausedDisplayChange, "Paused — display change in progress"),
            (.awaitingRestore, .pausedDisplayChange, "Paused — display change in progress"),
            (.dockedSetAbsent, .pausedDeskAbsent, "Paused — desk monitors not connected"),
            (.layoutUnverified, .pausedLayoutUnverified, "Paused — monitor layout not verified"),
            (.screensAsleep, .pausedScreensAsleep, "Paused — screens are off"),
            (.sessionNotReady, .pausedWaitingForWindows, "Paused — waiting for your windows after wake"),
            (.restoring, .restoring, "Restoring windows…"),
            (.accessibilityMissing, .accessibilityMissing, "Accessibility access needed")
        ]
        for (refusal, status, text) in cases {
            sut.pauseReason = refusal
            XCTAssertEqual(sut.status, status, "\(refusal)")
            XCTAssertEqual(sut.statusText(now: now), text, "\(refusal)")
        }
        // A pause outranks attention and auto-restore off; accessibility outranks a pause.
        sut.state = .attention
        sut.autoRestoreEnabled = false
        sut.pauseReason = .dockedSetAbsent
        XCTAssertEqual(sut.status, .pausedDeskAbsent)
        sut.pauseReason = nil
        XCTAssertEqual(sut.status, .attention)
        sut.pauseReason = .layoutUnverified
        sut.accessibilityGranted = false
        XCTAssertEqual(sut.status, .accessibilityMissing)
    }

    func testLastResultLines() {
        let date = Date(timeIntervalSince1970: 0)
        let fmt: (Date) -> String = { _ in "2:35 PM" }
        XCTAssertEqual(sut.lastResultLine(timeFormatter: fmt), "No restore yet")
        XCTAssertFalse(sut.isLastResultClickable)
        sut.lastResult = .windows(restored: 22, total: 24, date: date)
        XCTAssertEqual(sut.lastResultLine(timeFormatter: fmt), "Last restore: 22 of 24 windows, 2:35 PM")
        XCTAssertTrue(sut.isLastResultClickable)
        sut.lastResult = .monitorsFixed(date: date)
        XCTAssertEqual(sut.lastResultLine(timeFormatter: fmt), "Last restore: monitors fixed, 2:35 PM")
    }

    func testActionsForwardWhenEnabledAndNoOpWhenDisabled() async {
        await sut.saveNow()
        await sut.restoreNow()
        await sut.fixMonitors()
        XCTAssertEqual([fake.saves, fake.restores, fake.fixes], [1, 1, 1])
        sut.state = .working
        await sut.saveNow()
        await sut.restoreNow()
        await sut.fixMonitors()
        XCTAssertEqual([fake.saves, fake.restores, fake.fixes], [1, 1, 1])
    }

    // MARK: Last restore detail

    private actor GatedLoader: LastRestoreDetailLoading {
        private var continuations: [CheckedContinuation<LastRestoreLoad, Never>] = []
        func load() async -> LastRestoreLoad {
            await withCheckedContinuation { continuations.append($0) }
        }
        var pending: Int { continuations.count }
        func resolve(_ index: Int, with result: LastRestoreLoad) { continuations[index].resume(returning: result) }
    }

    private func detail(_ date: Date, restored: Int = 3, total: Int = 3) -> LastRestoreDetail {
        LastRestoreDetail(restoredAt: date, trigger: .launch, monitorLine: nil, appLines: ["A — 3 restored"],
                          overflowCount: 0, restoredCount: restored, totalCount: total)
    }

    func testSlowerEarlierLoadCannotOverwriteNewerOne() async throws {
        let loader = GatedLoader()
        let vm = MenuBarViewModel(detailLoader: loader)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let first = Task { await vm.refreshLastRestoreDetail() }
        while await loader.pending < 1 { await Task.yield() }
        let second = Task { await vm.refreshLastRestoreDetail() }
        while await loader.pending < 2 { await Task.yield() }
        await loader.resolve(1, with: .loaded(detail(newer)))
        await second.value
        await loader.resolve(0, with: .loaded(detail(older)))
        await first.value
        XCTAssertEqual(vm.lastRestoreDetail?.restoredAt, newer)
    }

    func testRelaunchFallsBackToLogAndShowsDateWhenNotToday() async {
        struct Fixed: LastRestoreDetailLoading {
            let result: LastRestoreLoad
            func load() async -> LastRestoreLoad { result }
        }
        let locale = Locale(identifier: "en_US")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let vm = MenuBarViewModel(detailLoader: Fixed(result: .loaded(detail(now.addingTimeInterval(-3 * 86_400)))))
        XCTAssertFalse(vm.hasLastRestore)
        XCTAssertEqual(vm.lastResultLine(), "No restore yet")
        await vm.refreshLastRestoreDetail()
        XCTAssertTrue(vm.hasLastRestore)
        let stamp = RestoreDetailFormatter.timestamp(now.addingTimeInterval(-3 * 86_400), now: now,
                                                     calendar: cal, locale: locale)
        XCTAssertEqual(vm.lastResultLine(now: now, calendar: cal, locale: locale),
                       "Last restore: 3 of 3 windows, \(stamp)")
        XCTAssertTrue(stamp.contains("2027") || stamp.contains("2026"), "an earlier day includes the date: \(stamp)")
    }

    func testLastResultLineUsesYesterdayAt() {
        let locale = Locale(identifier: "en_US")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 0)) ?? .distantPast
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 20, minute: 27)) ?? .distantPast
        sut.lastResult = .windows(restored: 3, total: 4, date: date)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                         calendar: cal, timeZone: cal.timeZone)
        XCTAssertEqual(sut.lastResultLine(now: now, calendar: cal, locale: locale),
                       "Last restore: 3 of 4 windows, Yesterday at \(date.formatted(timeStyle))")
    }

    /// A4: a manual Fix Monitors that found nothing to fix reads "already in order", in memory and after relaunch.
    func testLastResultLineMonitorsAlreadyInOrder() {
        let date = Date(timeIntervalSince1970: 1_000)
        sut.lastResult = .monitorsAlreadyInOrder(date: date)
        let line = sut.lastResultLine(timeFormatter: { _ in "2:35 PM" })
        XCTAssertEqual(line, "Last restore: monitors already in order, 2:35 PM")
        sut.lastResult = .monitorsFixed(date: date)
        XCTAssertEqual(sut.lastResultLine(timeFormatter: { _ in "2:35 PM" }), "Last restore: monitors fixed, 2:35 PM")
    }

    func testEffectiveLastResultFromAlreadyInOrderDetail() async {
        struct Fixed: LastRestoreDetailLoading {
            let detail: LastRestoreDetail
            func load() async -> LastRestoreLoad { .loaded(detail) }
        }
        let date = Date(timeIntervalSince1970: 1_000)
        let inOrder = MenuBarViewModel(detailLoader: Fixed(
            detail: RestoreDetailFormatter.detail(monitorFix: .alreadyInOrder, date: date)))
        await inOrder.refreshLastRestoreDetail()
        XCTAssertEqual(inOrder.effectiveLastResult, .monitorsAlreadyInOrder(date: date))
        let fixed = MenuBarViewModel(detailLoader: Fixed(
            detail: RestoreDetailFormatter.detail(monitorFix: .verified, date: date)))
        await fixed.refreshLastRestoreDetail()
        XCTAssertEqual(fixed.effectiveLastResult, .monitorsFixed(date: date))
    }

    func testUnreadableLogKeepsSubmenuAvailable() async {
        struct Bad: LastRestoreDetailLoading { func load() async -> LastRestoreLoad { .unreadable } }
        let vm = MenuBarViewModel(detailLoader: Bad())
        await vm.refreshLastRestoreDetail()
        XCTAssertTrue(vm.lastRestoreUnreadable)
        XCTAssertTrue(vm.hasLastRestore)
        XCTAssertNil(vm.lastRestoreDetail)
    }

    func testMonitorFixOutcomeBuildsDetailWithoutLogRead() {
        let vm = MenuBarViewModel()
        let date = Date()
        vm.apply(.monitorsFixed(.verified, date: date))
        XCTAssertEqual(vm.lastRestoreDetail?.monitorLine, "Monitors: fixed")
        XCTAssertEqual(vm.lastRestoreDetail?.appLines, [])
        XCTAssertTrue(vm.hasLastRestore)
    }
}
