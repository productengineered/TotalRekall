import XCTest
@testable import TotalRekall

/// Regression tests: an Accessibility re-grant must be picked up by the poll without
/// relaunch (an accessory app rarely receives didBecomeActive), and a relaunch path must exist.
private final class MutableTrustChecker: AccessibilityTrustChecking, @unchecked Sendable {
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
final class AccessibilityMonitorRegrantTests: XCTestCase {
    func testDefaultIntervalsMeetDetectionTargets() {
        // Re-grant within 5 s and revocation within 3 s (local checks).
        XCTAssertLessThanOrEqual(AccessibilityMonitor.defaultUntrustedPollInterval, .seconds(2))
        XCTAssertLessThanOrEqual(AccessibilityMonitor.defaultTrustedPollInterval, .seconds(3))
    }

    func testPollIntervalFollowsTrustState() {
        let checker = MutableTrustChecker(false)
        let sut = AccessibilityMonitor(
            checker: checker, trustedPollInterval: .seconds(30), untrustedPollInterval: .seconds(1),
            notificationCenter: NotificationCenter()
        )
        XCTAssertEqual(sut.currentPollInterval, .seconds(1))
        checker.trusted = true
        sut.refresh()
        XCTAssertEqual(sut.currentPollInterval, .seconds(30))
    }

    func testTimerPollDetectsRegrantAndNotifiesWithoutActivation() async throws {
        let checker = MutableTrustChecker(false)
        // Trusted interval is huge: only the fast untrusted cadence can catch the grant in time.
        let sut = AccessibilityMonitor(
            checker: checker, trustedPollInterval: .seconds(3600), untrustedPollInterval: .milliseconds(20),
            notificationCenter: NotificationCenter()
        )
        var changes: [Bool] = []
        sut.onChange = { changes.append($0) }
        sut.start()
        defer { sut.stop() }

        checker.trusted = true
        for _ in 0..<100 where !sut.isTrusted {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sut.isTrusted)
        XCTAssertEqual(changes, [true])
    }

    func testRevocationAfterRegrantStillDetectedByPoll() async throws {
        let checker = MutableTrustChecker(false)
        let sut = AccessibilityMonitor(
            checker: checker, trustedPollInterval: .milliseconds(20), untrustedPollInterval: .milliseconds(20),
            notificationCenter: NotificationCenter()
        )
        var changes: [Bool] = []
        sut.onChange = { changes.append($0) }
        sut.start()
        defer { sut.stop() }

        checker.trusted = true
        for _ in 0..<100 where !sut.isTrusted { try await Task.sleep(for: .milliseconds(20)) }
        checker.trusted = false
        for _ in 0..<100 where sut.isTrusted { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(changes, [true, false])
    }

    func testRelauncherPassesPathAndPIDAsPositionalArguments() {
        let url = URL(fileURLWithPath: "/Applications/Total \"Rekall\".app")
        let sut = AppRelauncher(bundleURL: url, processID: 4242)
        XCTAssertEqual(sut.arguments, ["-c", AppRelauncher.script, "sh", "4242", url.path])
        XCTAssertFalse(AppRelauncher.script.contains(url.path), "path must not be interpolated into the script")
        XCTAssertTrue(AppRelauncher.script.contains("kill -0"), "must wait for this instance to exit (InstanceLock)")
    }

    func testRelaunchItemTitleIsPresent() {
        XCTAssertFalse(MenuBarViewModel.relaunchForAccessibilityTitle.isEmpty)
    }
}
