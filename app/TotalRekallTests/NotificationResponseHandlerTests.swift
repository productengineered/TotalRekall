import XCTest
import UserNotifications
@testable import TotalRekall

@MainActor
private final class RecordingRevealer: FileRevealing {
    private(set) var revealed: [URL] = []
    func reveal(_ url: URL) { revealed.append(url) }
}

@MainActor
final class NotificationResponseHandlerTests: XCTestCase {
    private let logURL = URL(fileURLWithPath: "/tmp/tr-test/restore-log.json")
    private let diagURL = URL(fileURLWithPath: "/tmp/tr-test/diagnostics", isDirectory: true)

    private func makeSUT(logExists: Bool, revealer: RecordingRevealer,
                         diagnostics: RecordingDiagnostics = RecordingDiagnostics()) -> NotificationResponseHandler {
        NotificationResponseHandler(logURL: logURL, diagnosticsDirectory: diagURL, revealer: revealer,
                                    fileExists: { _ in logExists }, diagnostics: diagnostics)
    }

    func testClickRevealsRestoreLogWhenItExists() {
        let revealer = RecordingRevealer()
        makeSUT(logExists: true, revealer: revealer).handleClick(cycleID: UUID())
        XCTAssertEqual(revealer.revealed, [logURL])
    }

    func testClickRevealsDiagnosticsFolderWhenLogIsMissing() {
        let revealer = RecordingRevealer()
        makeSUT(logExists: false, revealer: revealer).handleClick(cycleID: nil)
        XCTAssertEqual(revealer.revealed, [diagURL])
    }

    func testClickIsRecordedInNotificationsCategoryWithCycleID() {
        let diagnostics = RecordingDiagnostics()
        let cycleID = UUID()
        makeSUT(logExists: true, revealer: RecordingRevealer(), diagnostics: diagnostics)
            .handleClick(cycleID: cycleID)
        let event = diagnostics.events.first
        XCTAssertEqual(event?.category, .notifications)
        XCTAssertEqual(event?.name, "notification-clicked")
        XCTAssertEqual(event?.cycleID, cycleID)
        XCTAssertEqual(event?.fields["revealed"], .string("restore-log"))
    }

    func testPresentationOptionsAreBannerAndList() {
        XCTAssertEqual(NotificationResponseHandler.presentationOptions, [.banner, .list])
    }
}
