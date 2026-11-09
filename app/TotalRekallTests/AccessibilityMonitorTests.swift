import XCTest
@testable import TotalRekall

private final class FakeTrustChecker: AccessibilityTrustChecking, @unchecked Sendable {
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
final class AccessibilityMonitorTests: XCTestCase {
    func testInitialStateReflectsChecker() {
        XCTAssertTrue(AccessibilityMonitor(checker: FakeTrustChecker(true)).isTrusted)
        XCTAssertFalse(AccessibilityMonitor(checker: FakeTrustChecker(false)).isTrusted)
    }

    func testRefreshDetectsRevocationAndNotifiesOnce() {
        let checker = FakeTrustChecker(true)
        let sut = AccessibilityMonitor(checker: checker)
        var changes: [Bool] = []
        sut.onChange = { changes.append($0) }

        sut.refresh()
        XCTAssertEqual(changes, [])

        checker.trusted = false
        sut.refresh()
        sut.refresh()
        XCTAssertFalse(sut.isTrusted)
        XCTAssertEqual(changes, [false])
    }

    func testRefreshDetectsGrant() {
        let checker = FakeTrustChecker(false)
        let sut = AccessibilityMonitor(checker: checker)
        var changes: [Bool] = []
        sut.onChange = { changes.append($0) }
        checker.trusted = true
        sut.refresh()
        XCTAssertTrue(sut.isTrusted)
        XCTAssertEqual(changes, [true])
    }

    func testDidBecomeActiveTriggersRecheck() {
        let center = NotificationCenter()
        let checker = FakeTrustChecker(true)
        let sut = AccessibilityMonitor(checker: checker, pollInterval: .seconds(3600), notificationCenter: center)
        sut.start()
        defer { sut.stop() }
        checker.trusted = false
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(sut.isTrusted)
    }

    func testTimerPollDetectsRevocation() async throws {
        let checker = FakeTrustChecker(true)
        let sut = AccessibilityMonitor(checker: checker, pollInterval: .milliseconds(20), notificationCenter: NotificationCenter())
        sut.start()
        defer { sut.stop() }
        checker.trusted = false
        for _ in 0..<100 where sut.isTrusted {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(sut.isTrusted)
    }

    func testOpenSettingsUsesPrivacyAccessibilityDeepLink() {
        var opened: URL?
        let sut = AccessibilityMonitor(checker: FakeTrustChecker(true), urlOpener: { opened = $0 })
        sut.openAccessibilitySettings()
        XCTAssertEqual(
            opened?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
