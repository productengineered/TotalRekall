import XCTest
@testable import TotalRekall

final class DiagnosticsExporterTests: XCTestCase {
    private struct FakeBuilder: DiagnosticsBundleBuilding {
        var fail = false
        func build(into folder: URL) async throws -> DiagnosticsManifest {
            if fail { throw DiagnosticsExportError.stagingFailed }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("manifest.json"))
            return DiagnosticsManifest(createdAt: Date(), filesIncluded: ["manifest.json"], inputsMissing: [])
        }
    }

    /// Writes a small file at the destination; fails for directories listed in `failingDirectories`.
    private final class FakeZipper: FolderZipping, @unchecked Sendable {
        var failingDirectories: Set<String> = []
        var failEverything = false
        private(set) var calls: [URL] = []
        func zip(folder: URL, to destination: URL) async throws {
            calls.append(destination)
            if failEverything || failingDirectories.contains(destination.deletingLastPathComponent().path) {
                throw DiagnosticsExportError.zipFailed
            }
            try Data("zip".utf8).write(to: destination)
        }
    }

    private var root: URL!
    private var desktop: URL!
    private var fallback: URL!
    private var staging: URL!
    private var recorder: RecordingDiagnostics!
    private var zipper: FakeZipper!
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-tests-\(UUID().uuidString)", isDirectory: true)
        desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        fallback = root.appendingPathComponent("exports", isDirectory: true)
        staging = root.appendingPathComponent("tmp", isDirectory: true)
        for dir in [desktop, staging].compactMap({ $0 }) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        recorder = RecordingDiagnostics()
        zipper = FakeZipper()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSUT(builder: FakeBuilder = FakeBuilder(),
                         simulated: SimulatedExportFailure? = nil) -> DiagnosticsExporter {
        DiagnosticsExporter(builder: builder, zipper: zipper, recorder: recorder,
                            desktopDirectory: desktop, fallbackDirectory: fallback, stagingRoot: staging,
                            now: { [fixedDate] in fixedDate }, simulatedFailure: simulated)
    }

    private func names() -> [String] { recorder.events.map(\.name) }

    func testExportWritesZipToDesktopWithTimestampName() async throws {
        let result = await makeSUT().export()
        guard case .desktop(let url) = result else { return XCTFail("Expected desktop, got \(result)") }
        XCTAssertEqual(url.deletingLastPathComponent().path, desktop.path)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("TotalRekall-Diagnostics-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".zip"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(names(), ["export-started", "export-finished"])
    }

    func testClashingNameGetsNumericSuffix() async {
        let sut = makeSUT()
        let first = await sut.export()
        let second = await sut.export()
        let third = await sut.export()
        guard case .desktop(let one) = first, case .desktop(let two) = second, case .desktop(let three) = third else {
            return XCTFail("Expected three desktop exports")
        }
        XCTAssertTrue(two.lastPathComponent.hasSuffix("-2.zip"))
        XCTAssertTrue(three.lastPathComponent.hasSuffix("-3.zip"))
        XCTAssertEqual(Set([one, two, three]).count, 3)
    }

    func testDesktopFailureFallsBackAndRecordsFallback() async {
        zipper.failingDirectories = [desktop.path]
        let result = await makeSUT().export()
        guard case .fallback(let url) = result else { return XCTFail("Expected fallback, got \(result)") }
        XCTAssertEqual(url.deletingLastPathComponent().path, fallback.path)
        XCTAssertEqual(names(), ["export-started", "export-fallback", "export-finished"])
    }

    func testBothDestinationsFailingRecordsFailedAndNothingLeftBehind() async {
        zipper.failEverything = true
        let result = await makeSUT().export()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(names(), ["export-started", "export-failed"])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: desktop.path)) ?? [], [])
    }

    func testBuilderFailureRecordsFailed() async {
        let result = await makeSUT(builder: FakeBuilder(fail: true)).export()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(names().last, "export-failed")
    }

    func testStagingFolderAlwaysRemoved() async {
        _ = await makeSUT().export()
        zipper.failEverything = true
        _ = await makeSUT().export()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [], [])
    }

    func testSimulatedDesktopFailureUsesFallbackWithoutTouchingDesktop() async {
        let result = await makeSUT(simulated: .desktop).export()
        guard case .fallback = result else { return XCTFail("Expected fallback, got \(result)") }
        XCTAssertFalse(zipper.calls.contains { $0.deletingLastPathComponent().path == desktop.path })
    }

    func testSimulatedAllFailureFails() async {
        let result = await makeSUT(simulated: .all).export()
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(zipper.calls.isEmpty)
    }

    func testFinishedEventCarriesSizeFilesAndDurationOnly() async {
        _ = await makeSUT().export()
        let finished = recorder.events.first { $0.name == "export-finished" }
        XCTAssertEqual(Set(finished?.fields.keys ?? [:].keys), ["bytes", "files", "ms", "fallback"])
        XCTAssertEqual(finished?.fields["files"], .int(1))
    }

    func testRealDittoProducesAZip() async throws {
        let folder = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let dest = root.appendingPathComponent("out.zip")
        try await DittoZipper().zip(folder: folder, to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testDittoFailureThrows() async {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        do {
            try await DittoZipper().zip(folder: missing, to: root.appendingPathComponent("o.zip"))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? DiagnosticsExportError, .zipFailed)
        }
    }

    // MARK: - DittoZipper timeout race

    func testZipOutcome_exitZeroIsSuccessEvenIfWatchdogFired() {
        XCTAssertNil(DittoZipper.outcome(reason: .exit, status: 0, watchdogFired: true))
        XCTAssertNil(DittoZipper.outcome(reason: .exit, status: 0, watchdogFired: false))
    }

    func testZipOutcome_killedByWatchdogIsTimeoutOtherwiseFailure() {
        XCTAssertEqual(DittoZipper.outcome(reason: .uncaughtSignal, status: 15, watchdogFired: true), .zipTimedOut)
        XCTAssertEqual(DittoZipper.outcome(reason: .uncaughtSignal, status: 9, watchdogFired: false), .zipFailed)
        XCTAssertEqual(DittoZipper.outcome(reason: .exit, status: 1, watchdogFired: true), .zipFailed)
    }

    func testZip_hangingProcessTimesOut() async {
        var zipper = DittoZipper(timeout: 0.3)
        zipper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        zipper.makeArguments = { _, _ in ["30"] }
        let started = Date()
        do {
            try await zipper.zip(folder: URL(fileURLWithPath: "/tmp"), to: URL(fileURLWithPath: "/tmp/unused.zip"))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? DiagnosticsExportError, .zipTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testZip_quickSuccessfulProcessSucceeds() async throws {
        var zipper = DittoZipper(timeout: 5)
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        zipper.makeArguments = { _, _ in [] }
        try await zipper.zip(folder: URL(fileURLWithPath: "/tmp"), to: URL(fileURLWithPath: "/tmp/unused.zip"))
    }
}
