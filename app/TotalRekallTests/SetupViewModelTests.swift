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
private final class FakeDeskProvider: SetupDeskProviding {
    var desk: SetupDeskInfo?
    var stillDocked = true
    private(set) var named: [(key: String, name: String)] = []
    private(set) var handled: [String] = []
    func currentDesk() async -> SetupDeskInfo? { desk }
    func nameDesk(_ key: String, as name: String) async -> Bool {
        guard stillDocked else { return false }
        named.append((key, name))
        return true
    }
    func markHandled(_ key: String) { handled.append(key) }
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

    // MARK: Desk step (named desks)

    private func grantedSUT(desk: SetupDeskInfo?) -> (SetupViewModel, FakeDeskProvider) {
        let sut = makeSUT(trusted: true)
        let provider = FakeDeskProvider()
        provider.desk = desk
        sut.deskProvider = provider
        sut.evaluateLaunch()
        return (sut, provider)
    }

    private let dockedDesk = SetupDeskInfo(key: "k1", name: "Desk 1", otherNames: ["Home"])

    func testContinueWithExternalMonitorsShowsDockedStepPrefilledWithDefaultName() async {
        let (sut, _) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        XCTAssertEqual(sut.state, .namingDesk(.docked))
        XCTAssertEqual(sut.deskModel?.text, "Desk 1")
        XCTAssertEqual(sut.deskModel?.otherNames, ["Home"])
        XCTAssertTrue(sut.isWindowVisible)
    }

    func testSaveNamesTheDeskMarksItHandledAndCloses() async {
        let (sut, provider) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        sut.deskModel?.text = "  Office  "
        sut.deskModel?.save()
        await sut.deskSaveTask?.value
        XCTAssertEqual(provider.named.map(\.name), ["Office"])
        XCTAssertEqual(provider.named.map(\.key), ["k1"])
        XCTAssertEqual(provider.handled, ["k1"])
        XCTAssertFalse(sut.isWindowVisible)
        XCTAssertEqual(closeCount, 1)
    }

    func testSaveIsDisabledForDuplicateOrEmptyNameAndDoesNothing() async {
        let (sut, provider) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        sut.deskModel?.text = "home"
        XCTAssertEqual(sut.deskModel?.canSave, false)
        sut.deskModel?.save()
        sut.deskModel?.text = "   "
        XCTAssertEqual(sut.deskModel?.canSave, false)
        sut.deskModel?.save()
        XCTAssertNil(sut.deskSaveTask)
        XCTAssertTrue(provider.named.isEmpty)
        XCTAssertTrue(sut.isWindowVisible)
    }

    func testSaveWhenNoLongerDockedJustClosesWithoutNaming() async {
        let (sut, provider) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        provider.stillDocked = false
        sut.deskModel?.save()
        await sut.deskSaveTask?.value
        XCTAssertTrue(provider.named.isEmpty)
        XCTAssertEqual(provider.handled, ["k1"])
        XCTAssertFalse(sut.isWindowVisible)
    }

    func testEscapeInDockedStepKeepsDefaultNameMarksHandledAndCloses() async {
        let (sut, provider) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        sut.skip()
        sut.skip()
        XCTAssertTrue(provider.named.isEmpty)
        XCTAssertEqual(provider.handled, ["k1"])
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(eventNames().contains("setup-skipped"))
    }

    func testContinueWithBuiltInDisplayOnlyShowsUndockedStepAndDoneCloses() async {
        let (sut, provider) = grantedSUT(desk: nil)
        await sut.continueToDeskStep()
        XCTAssertEqual(sut.state, .namingDesk(.undocked))
        XCTAssertNil(sut.deskModel)
        sut.finishUndockedStep()
        sut.finishUndockedStep()
        XCTAssertFalse(sut.isWindowVisible)
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(provider.named.isEmpty)
        XCTAssertTrue(provider.handled.isEmpty)
    }

    func testContinueWithoutAProviderBehavesAsUndocked() async {
        let sut = makeSUT(trusted: true)
        sut.evaluateLaunch()
        await sut.continueToDeskStep()
        XCTAssertEqual(sut.state, .namingDesk(.undocked))
    }

    func testRepeatedGrantDoesNotKickTheDeskStepBackToGranted() async {
        let (sut, _) = grantedSUT(desk: dockedDesk)
        await sut.continueToDeskStep()
        sut.trustDidChange(true)
        XCTAssertEqual(sut.state, .namingDesk(.docked))
    }

    func testGrantedPrimaryIsContinueAndDeskCopyMatchesSpec() {
        let granted = SetupCopy(state: .granted, reason: .firstRun, paneName: "Accessibility")
        XCTAssertEqual(granted.primary, .continueSetup)
        XCTAssertEqual(granted.primaryTitle, "Continue")
        let docked = SetupCopy(state: .namingDesk(.docked), reason: .firstRun, paneName: "Accessibility")
        XCTAssertEqual(docked.title, "Name this desk")
        XCTAssertEqual(docked.primary, .saveDesk)
        XCTAssertTrue(docked.showsDeskField)
        let undocked = SetupCopy(state: .namingDesk(.undocked), reason: .firstRun, paneName: "Accessibility")
        XCTAssertEqual(undocked.body, "TotalRekall will ask you to name the desk when you connect to it.")
        XCTAssertEqual(undocked.primaryTitle, "Done")
        XCTAssertFalse(undocked.showsDeskField)
    }

    // MARK: Relaunch

    func testRelaunchSuggestedAfterTimeout() async {
        let sut = makeSUT(trusted: false)
        sut.evaluateLaunch()
        sut.openSystemSettings()
        await clock.waitForSleeper(deadline: .seconds(10))
        await clock.advance(by: .seconds(10))
        let reached = await waitUntil { sut.state == .relaunchSuggested }
        XCTAssertTrue(reached, "state should reach the expected value within the deadline")
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
        let reached = await waitUntil { sut.state == .relaunchSuggested }
        XCTAssertTrue(reached, "state should reach the expected value within the deadline")

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
        let reached = await waitUntil { sut.state == .granted }
        XCTAssertTrue(reached, "state should reach the expected value within the deadline")
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
