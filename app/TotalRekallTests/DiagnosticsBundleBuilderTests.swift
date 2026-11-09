import XCTest
@testable import TotalRekall

final class DiagnosticsBundleBuilderTests: XCTestCase {
    private let sentinel = "SENTINEL-SECRET-TITLE-7731"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func window(title: String, ordinal: Int, minimized: Bool = false) -> WindowSnapshot {
        WindowSnapshot(id: UUID(), bundleID: "com.example.app", appName: "Example", windowID: 1,
                       windowTitle: title, windowIndex: 0, displayFingerprint: "fp", displayIndex: 0,
                       panelSerial: "SERIAL-A", spaceOrdinal: ordinal, spaceUUID: nil, spaceIndex: 0,
                       frame: SnapshotFrame(x: 0, y: 0, width: 100, height: 100),
                       isFullscreen: false, isMinimized: minimized, zOrder: 0)
    }

    private func snapshotFile() -> SnapshotFile {
        let display = DisplaySnapshot(vendorID: 1, productID: 2, serialNumber: "", panelSerial: "SERIAL-A",
                                      unitNumber: 0, iokitLocationPath: nil,
                                      resolution: SnapshotSize(width: 100, height: 100), scaleFactor: 2,
                                      displayName: "D", originX: 0, originY: 0, isMain: true, cgDisplayID: nil)
        let config = DisplayConfigSnapshot(
            fingerprint: "fp", displayConfigName: "Desk", displays: [display], lastSnapshotDate: Date(),
            windows: [window(title: sentinel, ordinal: 1), window(title: sentinel, ordinal: 2, minimized: true)])
        return SnapshotFile(configurations: ["cfg": config])
    }

    private func restoreLog() -> RestoreLog {
        let result = RestoreWindowResult(snapshotID: UUID(), windowID: 1, bundleID: "com.example.app",
                                         appName: "Example", title: sentinel, status: .moved)
        return RestoreLog(results: [result], date: Date(), configKey: "cfg", capability: .full, layout: nil)
    }

    private func makeBuilder(withDiary: Bool = true, log: RestoreLog? = nil, logExists: Bool? = nil,
                             snapshot: SnapshotFile? = nil, spacesThrow: Bool = false) throws -> DiagnosticsBundleBuilder {
        var collected: [URL] = []
        if withDiary {
            let diary = root.appendingPathComponent("diagnostics.jsonl")
            try Data("{\"event\":\"x\"}\n".utf8).write(to: diary)
            collected = [diary, root.appendingPathComponent("diagnostics.1.jsonl")]
        }
        let files = collected
        let providers = DiagnosticsBundleProviders(
            diagnosticsFiles: { files },
            restoreLog: {
                guard let log else { throw RestoreLogError.readFailed("none") }
                return log
            },
            restoreLogExists: { logExists ?? (log != nil) },
            snapshot: { snapshot ?? SnapshotFile() },
            displays: {
                [LiveDisplay(displayID: 1, serial: .panel("SERIAL-A"),
                             frame: SnapshotFrame(x: 0, y: 0, width: 100, height: 100),
                             pixelSize: SnapshotSize(width: 200, height: 200), scaleFactor: 2, name: "D",
                             vendorID: 1, productID: 2, serialNumber: "", unitNumber: 0, isMain: true)]
            },
            topology: {
                if spacesThrow { throw SpaceBridgeError.topologyUnavailable }
                return [DisplaySpaces(serial: .panel("SERIAL-A"),
                                      spaces: [SpaceInfo(id64: 1, type: 0), SpaceInfo(id64: 2, type: 0)])]
            },
            currentDesktopOrdinals: { ["SERIAL-A": 1] },
            appInfo: {
                AppInfoReport(appVersion: "1", build: "1", macOSVersion: "test",
                              spaceBridgeCapability: "full", accessibilityTrusted: true)
            })
        return DiagnosticsBundleBuilder(providers: providers)
    }

    private func names(in folder: URL) throws -> Set<String> {
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var result = Set(items)
        let diary = folder.appendingPathComponent("diagnostics")
        if let inner = try? FileManager.default.contentsOfDirectory(atPath: diary.path) {
            result.formUnion(inner.map { "diagnostics/\($0)" })
        }
        return result
    }

    func testBundleContainsExpectedFiles() async throws {
        let out = root.appendingPathComponent("out")
        let builder = try makeBuilder(log: restoreLog(), snapshot: snapshotFile())
        try await builder.build(into: out)
        let found = try names(in: out)
        for expected in ["diagnostics/diagnostics.jsonl", "restore-log.json", "snapshot-summary.json",
                         "display-topology.json", "app-info.json", "manifest.json"] {
            XCTAssertTrue(found.contains(expected), "missing \(expected)")
        }
    }

    func testNoWindowTitlesInBundle() async throws {
        let out = root.appendingPathComponent("out")
        let builder = try makeBuilder(log: restoreLog(), snapshot: snapshotFile())
        try await builder.build(into: out)
        for name in try names(in: out) {
            let url = out.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(sentinel), "\(name) leaks a title")
        }
        let data = try Data(contentsOf: out.appendingPathComponent("restore-log.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.map { $0["title"] as? String }, ["[redacted]"])
    }

    func testMissingInputsAreListed() async throws {
        let out = root.appendingPathComponent("out")
        let builder = try makeBuilder(withDiary: false, log: nil, snapshot: nil)
        let manifest = try await builder.build(into: out)
        XCTAssertTrue(manifest.inputsMissing.contains("restore-log"))
        XCTAssertTrue(manifest.inputsMissing.contains("snapshot"))
        XCTAssertTrue(manifest.inputsMissing.contains("diagnostics"))
        let data = try Data(contentsOf: out.appendingPathComponent("manifest.json"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("restore-log"))
        XCTAssertTrue(text.contains("snapshot"))
    }

    func testUndecodableRestoreLogIsReplacedByNote() async throws {
        let out = root.appendingPathComponent("out")
        let builder = try makeBuilder(log: nil, logExists: true, snapshot: snapshotFile())
        let manifest = try await builder.build(into: out)
        let text = try String(contentsOf: out.appendingPathComponent("restore-log.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("could not be read"))
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
        XCTAssertTrue(manifest.inputsMissing.contains("restore-log (undecodable)"))
    }

    func testSpacesUnavailableIsRecordedNotFatal() async throws {
        let out = root.appendingPathComponent("out")
        let builder = try makeBuilder(log: restoreLog(), snapshot: snapshotFile(), spacesThrow: true)
        let manifest = try await builder.build(into: out)
        let data = try Data(contentsOf: out.appendingPathComponent("display-topology.json"))
        let report = try JSONDecoder().decode(DisplayTopologyReport.self, from: data)
        XCTAssertEqual(report.spaces, "unavailable")
        XCTAssertNil(report.displays.first?.desktopCount)
        XCTAssertTrue(manifest.inputsMissing.contains("spaces"))
    }

    func testSnapshotSummaryCountsPerDesktop() {
        let summary = SnapshotSummaryReport.make(from: snapshotFile())
        let config = summary.configurations.first
        XCTAssertEqual(config?.windowCount, 2)
        XCTAssertEqual(config?.windowCountsPerDesktop["SERIAL-A#1"], 1)
        XCTAssertEqual(config?.windowCountsPerDesktop["SERIAL-A#2"], 1)
        XCTAssertEqual(config?.minimizedCount, 1)
        XCTAssertEqual(config?.panelSerials, ["SERIAL-A"])
    }
}
