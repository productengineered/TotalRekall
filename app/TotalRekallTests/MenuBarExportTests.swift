import XCTest
@testable import TotalRekall

@MainActor
final class MenuBarExportTests: XCTestCase {
    private final class FakeExporter: DiagnosticsExporting, @unchecked Sendable {
        var result: DiagnosticsExportResult = .desktop(URL(fileURLWithPath: "/tmp/a.zip"))
        var gate: AsyncStream<Void>?
        var calls = 0
        func export() async -> DiagnosticsExportResult {
            calls += 1
            if let gate { for await _ in gate { break } }
            return result
        }
    }

    private final class FakeRevealer: FileRevealing {
        var revealed: [URL] = []
        func reveal(_ url: URL) { revealed.append(url) }
    }

    private var exporter: FakeExporter!
    private var revealer: FakeRevealer!
    private var sut: MenuBarViewModel!

    override func setUp() {
        super.setUp()
        exporter = FakeExporter()
        revealer = FakeRevealer()
        sut = MenuBarViewModel(exporter: exporter, revealer: revealer)
    }

    /// Polls until `condition` holds or the deadline passes; never waits open-ended.
    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testExportEnabledInEveryStateIncludingMissingAccessibility() {
        for state in [AppState.idle, .working, .attention] {
            sut.state = state
            XCTAssertTrue(sut.isExportEnabled)
        }
        sut.accessibilityGranted = false
        XCTAssertTrue(sut.isExportEnabled)
        XCTAssertEqual(sut.exportTitle, "Export Diagnostics…")
    }

    func testDesktopExportRevealsAndSetsNotice() async {
        await sut.exportDiagnostics()
        XCTAssertEqual(revealer.revealed, [URL(fileURLWithPath: "/tmp/a.zip")])
        XCTAssertEqual(sut.exportNotice, "Diagnostics saved to the Desktop")
        XCTAssertFalse(sut.isExporting)
    }

    func testFallbackExportRevealsAndSetsFallbackNotice() async {
        exporter.result = .fallback(URL(fileURLWithPath: "/tmp/b.zip"))
        await sut.exportDiagnostics()
        XCTAssertEqual(revealer.revealed.count, 1)
        XCTAssertEqual(sut.exportNotice, "Couldn't use the Desktop. Saved in Total Rekall's folder.")
    }

    func testFailureDoesNotRevealAndResetsExporting() async {
        exporter.result = .failed
        await sut.exportDiagnostics()
        XCTAssertTrue(revealer.revealed.isEmpty)
        XCTAssertEqual(sut.exportNotice, "Export failed")
        XCTAssertFalse(sut.isExporting)
        XCTAssertTrue(sut.isExportEnabled)
    }

    func testItemDisabledAndRetitledWhileExportingAndSecondClickIgnored() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        exporter.gate = stream
        let first = Task { await sut.exportDiagnostics() }
        await waitUntil("exporter entry") { sut.isExporting && exporter.calls == 1 }
        XCTAssertFalse(sut.isExportEnabled)
        XCTAssertEqual(sut.exportTitle, "Exporting Diagnostics…")
        await sut.exportDiagnostics()
        XCTAssertEqual(exporter.calls, 1)
        continuation.yield()
        await first.value
        XCTAssertTrue(sut.isExportEnabled)
        XCTAssertEqual(exporter.calls, 1)
    }

    func testNoticeClearsOnlyAfterItWasShownAndMenuClosed() async {
        await sut.exportDiagnostics()
        sut.clearShownNotices()
        XCTAssertNotNil(sut.exportNotice, "not shown yet, so it must survive a close")
        sut.markExportNoticeShown()
        sut.clearShownNotices()
        XCTAssertNil(sut.exportNotice)
    }

    func testNewExportClearsPendingNotice() async {
        await sut.exportDiagnostics()
        exporter.result = .desktop(URL(fileURLWithPath: "/tmp/c.zip"))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        exporter.gate = stream
        let task = Task { await sut.exportDiagnostics() }
        await waitUntil("exporter entry") { sut.isExporting && exporter.calls == 2 }
        XCTAssertNil(sut.exportNotice)
        continuation.yield()
        await task.value
    }
}
