import XCTest
@testable import TotalRekall

final class SetupPresentationPolicyTests: XCTestCase {
    func testLaunchDecisionMatrix() {
        let cases: [(completed: Bool, trusted: Bool, expected: SetupLaunchDecision)] = [
            (false, false, .showNeedsPermission(.firstRun)),   // first launch
            (false, true, .showGranted),                       // first launch, already granted
            (true, true, .hidden),                             // completed and trusted
            (true, false, .showNeedsPermission(.revoked))      // untrusted at launch after setup
        ]
        for item in cases {
            XCTAssertEqual(
                SetupPresentationPolicy.launchDecision(setupCompleted: item.completed, isTrusted: item.trusted),
                item.expected, "completed=\(item.completed) trusted=\(item.trusted)"
            )
        }
    }

    func testMenuReasonFollowsHistory() {
        XCTAssertEqual(SetupPresentationPolicy.menuReason(setupCompleted: false), .firstRun)
        XCTAssertEqual(SetupPresentationPolicy.menuReason(setupCompleted: true), .revoked)
    }

    func testRevocationShowsOnceThenReArmsOnRegrant() {
        var tracker = SetupRevocationTracker(startsTrusted: true)
        XCTAssertTrue(tracker.trustChanged(to: false), "first revocation shows")
        XCTAssertFalse(tracker.trustChanged(to: false), "repeat notification for the same revocation does not")
        XCTAssertFalse(tracker.trustChanged(to: true), "a grant never shows the revoked window")
        XCTAssertTrue(tracker.trustChanged(to: false), "re-grant then revoke shows again")
    }

    func testUntrustedLaunchDoesNotArmRevocation() {
        var tracker = SetupRevocationTracker(startsTrusted: false)
        XCTAssertFalse(tracker.trustChanged(to: false))
        XCTAssertFalse(tracker.trustChanged(to: true))
        XCTAssertTrue(tracker.trustChanged(to: false))
    }

    func testPaneNameByOSVersion() {
        let cases: [(major: Int, expected: String)] = [
            (26, "Accessibility"),
            (27, "Device Control and Data Access"),
            (28, "Device Control and Data Access")
        ]
        for item in cases {
            let version = OperatingSystemVersion(majorVersion: item.major, minorVersion: 0, patchVersion: 0)
            XCTAssertEqual(SetupPresentationPolicy.paneName(for: version), item.expected, "macOS \(item.major)")
        }
    }
}
