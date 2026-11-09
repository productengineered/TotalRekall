import XCTest
@testable import TotalRekall

private final class SetupFakeTrustChecker: AccessibilityTrustChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var trusted: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func isProcessTrusted() -> Bool { trusted }
}

@MainActor
private final class FakeCompletionStore: SetupCompletionStoring {
    var isCompleted: Bool
    init(completed: Bool = false) { isCompleted = completed }
    func markCompleted() { isCompleted = true }
}

@MainActor
final class SetupViewModelTests: XCTestCase {
    private var checker: SetupFakeTrustChecker!
    private var monitor: AccessibilityMonitor!
    private var store: FakeCompletionStore!
    private var diagnostics: RecordingDiagnostics!
    private var clock: TestClock!
    private var openedURLs: [URL] = []
    private var relaunchCount = 0
    private var presentCount = 0
    private var closeCount = 0
    private var currentDate = Date(timeIntervalSince1970: 1_000)

    private func makeSUT(trusted: Bool, completed: Bool = false, osMajor: Int = 26) -> SetupViewModel {
        checker = SetupFakeTrustChecker(trusted)
        openedURLs = []
        monitor = AccessibilityMonitor(checker: checker, pollInterval: .seconds(60)) { [unowned self] url in
            self.openedURLs.append(url)
        }
        store = FakeCompletionStore(completed: completed)
        diagnostics = RecordingDiagnostics()
        clock = TestClock()
        let sut = SetupViewModel(
            status: monitor, store: store, diagnostics: diagnostics, clock: clock,
            now: { [unowned self] in self.currentDate },
            osVersion: OperatingSystemVersion(majorVersion: osMajor, minorVersion: 0, patchVersion: 0),
            relaunchAction: { [unowned self] in self.relaunchCount += 1 }
        )
        sut.onPresent = { [unowned self] in self.presentCount += 1 }
        sut.onClose = { [unowned self] in self.closeCount += 1 }
        return sut
    }

    /// Flip the fake permission and let the monitor notify, as the 2 s poll would.
    private func setTrusted(_ value: Bool, _ sut: SetupViewModel) {
        checker.trusted = value
        monitor.refresh()
        sut.trustDidChange(value)
    }

    private func eventNames() -> [String] { diagnostics.events.map(\.name) }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    // MARK: Launch

    func testFirstLaunchUntrustedShowsFirstRun() {
        let sut = makeSUT(trusted: false)
        XCTAssertTrue(sut.evaluateLaunch())
        XCTAssertEqual(sut.state, .needsPermission(.firstRun))
        XCTAssertTrue(sut.isWindowVisible)
        XCTAssertEqual(presentCount, 1)
        XCTAssertEqual(diagnostics.events.first, .setupShown(reason: .firstLaunch))
    }

    func testFirstLaunchAlreadyTrustedShowsGrantedAndStoresCompletion() {
        let sut = makeSUT(trusted: true)
        XCTAssertTrue(sut.evaluateLaunch())
        XCTAssertEqual(sut.state, .granted)
        XCTAssertTrue(store.isCompleted)
        XCTAssertEqual(diagnostics.events.first, .setupShown(reason: .firstLaunchTrusted))
    }

    func testCompletedAndTrustedStaysHidden() {
        let sut = makeSUT(trusted: true, completed: true)
        XCTAssertFalse(sut.evaluateLaunch())
        XCTAssertFalse(sut.isWindowVisible)
        XCTAssertEqual(presentCount, 0)
        XCTAssertTrue(diagnostics.events.isEmpty)
    }

    func testCompletedButUntrustedAtLaunchShowsRevoked() {
        let sut = makeSUT(trusted: false, completed: true)
        XCTAssertTrue(sut.evaluateLaunch())
        XCTAssertEqual(sut.state, .needsPermission(.revoked))
        XCTAssertEqual(diagnostics.events.first, .setupShown(reason: .revoked))
    }

    // MARK: Open settings, grant

    func testOpenSettingsOpensAccessibilityPane() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        )
        XCTAssertEqual(sut.state, .waitingForGrant)
        XCTAssertTrue(eventNames().contains("setup-open-settings"))
    }

    func testGrantFlipsToDone() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        currentDate = currentDate.addingTimeInterval(7)
        setTrusted(true, sut)
        XCTAssertEqual(sut.state, .granted)
        XCTAssertTrue(store.isCompleted)
        let granted = diagnostics.events.last
        XCTAssertEqual(granted, .setupGranted(seconds: 7))
    }

    func testGrantFromNeedsPermissionAlsoCompletes() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        setTrusted(true, sut)
        XCTAssertEqual(sut.state, .granted)
        XCTAssertTrue(store.isCompleted)
    }

    func testSkipDoesNotStoreCompletion() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.skip()
        XCTAssertFalse(store.isCompleted)
        XCTAssertFalse(sut.isWindowVisible)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(eventNames().last, "setup-skipped")
    }

    func testSkipAndDoneAreIdempotent() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.skip()
        sut.skip()
        sut.done()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(eventNames().filter { $0 == "setup-skipped" }.count, 1)
    }

    func testDoneClosesGrantedWindowWithoutSkipEvent() {
        let sut = makeSUT(trusted: true)
        sut.evaluateLaunch()
        sut.done()
        XCTAssertFalse(sut.isWindowVisible)
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(eventNames().contains("setup-skipped"))
    }

    // MARK: Relaunch

    func testRelaunchSuggestedAfterTimeout() async {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        await clock.waitForSleeper(deadline: .seconds(10))
        await clock.advance(by: .seconds(10))
        await waitUntil { sut.state == .relaunchSuggested }
        XCTAssertEqual(sut.state, .relaunchSuggested)
        XCTAssertTrue(eventNames().contains("setup-relaunch-suggested"))

        sut.relaunch()
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertEqual(eventNames().last, "setup-relaunch")
    }

    func testRelaunchIsAlsoAvailableWhileWaiting() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        sut.relaunch()
        XCTAssertEqual(relaunchCount, 1)
    }

    func testOpenSettingsAgainReturnsToWaitingWithNewTimer() async {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        await clock.waitForSleeper(deadline: .seconds(10))
        await clock.advance(by: .seconds(10))
        await waitUntil { sut.state == .relaunchSuggested }

        sut.openSystemSettings()
        XCTAssertEqual(sut.state, .waitingForGrant)
        XCTAssertEqual(openedURLs.count, 2)
        await clock.waitForSleeper(deadline: .seconds(20))
    }

    func testGrantBeforeTimeoutCancelsSuggestion() async {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        await clock.waitForSleeper(deadline: .seconds(10))
        setTrusted(true, sut)
        await clock.advance(by: .seconds(10))
        await Task.yield()
        XCTAssertEqual(sut.state, .granted)
        XCTAssertFalse(eventNames().contains("setup-relaunch-suggested"))
    }

    // MARK: Revocation

    func testRevocationWhileHiddenShowsRevokedOnce() {
        let sut = makeSUT(trusted: true, completed: true)
        sut.evaluateLaunch()
        setTrusted(false, sut)
        XCTAssertEqual(sut.state, .needsPermission(.revoked))
        XCTAssertTrue(sut.isWindowVisible)
        XCTAssertEqual(diagnostics.events.last, .setupShown(reason: .revoked))

        sut.skip()
        sut.trustDidChange(false)
        XCTAssertFalse(sut.isWindowVisible, "same revocation does not reopen the window")

        setTrusted(true, sut)
        setTrusted(false, sut)
        XCTAssertTrue(sut.isWindowVisible, "grant then revoke shows again")
    }

    func testRevokedWhileGrantedWindowOpenReturnsToNeedsPermission() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        setTrusted(true, sut)
        XCTAssertEqual(sut.state, .granted)
        setTrusted(false, sut)
        XCTAssertEqual(sut.state, .needsPermission(.revoked))
        XCTAssertEqual(sut.reason, .revoked)
        XCTAssertEqual(diagnostics.events.last, .setupShown(reason: .revoked))
    }

    func testRevokedAgainWhileOpenLeavesStateUnchanged() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        let before = diagnostics.events.count
        sut.trustDidChange(false)
        XCTAssertEqual(sut.state, .waitingForGrant)
        XCTAssertEqual(diagnostics.events.count, before)
    }

    // MARK: Menu

    func testMenuClickWhileHiddenShowsByHistory() {
        let sut = makeSUT(trusted: false, completed: true)
        sut.presentFromMenu()
        XCTAssertEqual(sut.state, .needsPermission(.revoked))
        XCTAssertEqual(diagnostics.events.first, .setupShown(reason: .menu))
    }

    func testMenuClickWhileOpenKeepsState() {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        let before = presentCount
        sut.presentFromMenu()
        XCTAssertEqual(sut.state, .waitingForGrant)
        XCTAssertEqual(presentCount, before + 1, "window is fronted")
    }

    // MARK: Observation and copy

    func testObservingMonitorDetectsGrantWithoutOnChange() async {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.startObserving()
        checker.trusted = true
        monitor.refresh()
        await waitUntil { sut.state == .granted }
        XCTAssertEqual(sut.state, .granted)
        XCTAssertNil(monitor.onChange, "AppDelegate's onChange slot is left alone")
        sut.stopObserving()
    }

    func testPaneNameOnMacOS27() {
        XCTAssertEqual(makeSUT(trusted: false, osMajor: 27).paneName, "Device Control and Data Access")
        XCTAssertEqual(makeSUT(trusted: false, osMajor: 26).paneName, "Accessibility")
    }

    func testCompletionStoreUsesSetupCompletedKey() {
        let suite = "SetupViewModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsSetupCompletionStore(defaults: defaults)
        XCTAssertFalse(sut.isCompleted)
        sut.markCompleted()
        XCTAssertTrue(sut.isCompleted)
        XCTAssertTrue(defaults.bool(forKey: "setupCompleted"))
    }
}
