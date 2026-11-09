import XCTest
@testable import TotalRekall

// MARK: - Fakes (private to this file)

private struct TrailTrust: AccessibilityTrustChecking {
    func isProcessTrusted() -> Bool { true }
}

private struct TrailDisplays: DisplayProviding {
    let serials: [String]
    func currentDisplays() -> [LiveDisplay] {
        serials.enumerated().map { index, s in
            LiveDisplay(displayID: UInt32(index + 1), serial: s == "builtin" ? .builtin : .panel(s),
                        frame: SnapshotFrame(x: Double(index * 100), y: 0, width: 100, height: 100),
                        pixelSize: SnapshotSize(width: 100, height: 100), scaleFactor: 1, name: s,
                        vendorID: 1, productID: 1, serialNumber: s, unitNumber: 0, isMain: index == 0)
        }
    }
}

private struct TrailSnapshots: SnapshotLoading {
    let file: SnapshotFile
    func load() async throws -> SnapshotFile { file }
}

private struct TrailFixer: MonitorFixing {
    func fix(learned: MonitorLayout) -> FixOutcome { .skipped(reason: "test") }
}

private struct TrailTopology: SpaceTopologyProviding {
    func topology() async throws -> [DisplaySpaces] { [] }
}

private struct TrailLive: LiveWindowProviding {
    func liveWindows(ids: Set<UInt32>) async -> [LiveWindowState] { [] }
}

private struct TrailLogWriter: RestoreLogWriting {
    func write(_ log: RestoreLog) throws {}
}

private struct TrailRestorer: WindowRestoring {
    func execute(_ plan: RestorePlan) async -> [RestoreWindowResult] {
        plan.windows.map { RestoreWindowResult(planned: $0, status: .moved, detail: "frame ok, attempts 1") }
    }
}

// MARK: - Tests

final class DiagnosticsRestoreTrailTests: XCTestCase {
    private let serials = ["builtin", "PANEL1"]
    private let sentinel = "SENTINEL-TITLE-9f3a1c"

    private func window(_ id: UInt32) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: "com.example.app", appName: "ExampleApp", windowID: id,
            windowTitle: "\(sentinel)-\(id)", windowIndex: 0, displayFingerprint: nil, displayIndex: 0,
            panelSerial: "PANEL1", spaceOrdinal: 2, spaceUUID: nil, spaceIndex: 0,
            frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10),
            isFullscreen: false, isMinimized: false, zOrder: 0
        )
    }

    private func snapshotFile() -> SnapshotFile {
        let key = SnapshotKey.make(panelSerials: serials)
        let displays = serials.enumerated().map { index, s in
            DisplaySnapshot(vendorID: 1, productID: 1, serialNumber: s, panelSerial: s, unitNumber: 0,
                            iokitLocationPath: nil, resolution: SnapshotSize(width: 100, height: 100),
                            scaleFactor: 1, displayName: s, originX: index * 100, originY: 0,
                            isMain: index == 0, cgDisplayID: nil)
        }
        let config = DisplayConfigSnapshot(
            fingerprint: key, displayConfigName: "test", displays: displays, lastSnapshotDate: Date(),
            windows: (1...3).map { window(UInt32($0)) }
        )
        return SnapshotFile(configurations: [key: config])
    }

    private func runRestore() async -> (events: [DiagnosticsEvent], cycleID: UUID) {
        let recorder = RecordingDiagnostics()
        let coordinator = RestoreCoordinator(
            trust: TrailTrust(), displays: TrailDisplays(serials: serials),
            snapshots: TrailSnapshots(file: snapshotFile()),
            learnedLayout: { MonitorLayout(origins: ["builtin": .init(x: 0, y: 0), "PANEL1": .init(x: 100, y: 0)]) },
            fixer: TrailFixer(), topology: TrailTopology(), liveWindows: TrailLive(),
            restorer: TrailRestorer(), logWriter: TrailLogWriter(), capability: .full,
            now: { Date(timeIntervalSince1970: 1_000) }, diagnostics: recorder
        )
        let context = CycleContext(trigger: .displayChange)
        _ = await coordinator.restoreNow(context: context)
        return (recorder.events, context.cycleID)
    }

    func testRestoreRecordsPlanAndOneResultPerWindowWithCycleID() async {
        let (events, cycleID) = await runRestore()
        let names = events.map(\.name)
        XCTAssertEqual(names.first, "restore-started")
        XCTAssertEqual(names.last, "restore-finished")
        XCTAssertTrue(names.contains("swap-check"))
        XCTAssertTrue(names.contains("monitor-fix"))
        XCTAssertEqual(events.filter { $0.name == "restore-plan" }.count, 1)
        let results = events.filter { $0.name == "window-result" }
        XCTAssertEqual(results.count, 3)
        for event in results {
            XCTAssertEqual(event.cycleID, cycleID)
            XCTAssertEqual(event.fields["status"], .string("moved"))
            XCTAssertEqual(event.fields["desktop_panel"], .string("PANEL1"))
            XCTAssertEqual(event.fields["desktop_ordinal"], .int(2))
            XCTAssertEqual(event.fields["bundle_id"], .string("com.example.app"))
            XCTAssertEqual(event.fields["detail"], .string("frame-written"))
        }
        let swap = events.first { $0.name == "swap-check" }
        XCTAssertEqual(swap?.fields["verdict"], .string("correct"))
        XCTAssertEqual(swap?.fields["learned_order"], .string("builtin,PANEL1"))
    }

    func testSentinelWindowTitleNeverAppearsInEventsOrJSON() async throws {
        let (events, _) = await runRestore()
        XCTAssertFalse(events.isEmpty)
        let data = try JSONEncoder().encode(events)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(sentinel))
        for event in events {
            XCTAssertFalse(String(describing: event).contains(sentinel))
        }
    }

    func testRestoreFinishedCarriesSummaryCounts() async {
        let (events, _) = await runRestore()
        let finished = events.last
        XCTAssertEqual(finished?.fields["total"], .int(3))
        XCTAssertEqual(finished?.fields["restored"], .int(3))
        XCTAssertEqual(finished?.fields["needs_attention"], .bool(false))
    }

    func testDetailKindIsBounded() {
        XCTAssertEqual(RestoreDetailKind(detail: nil), .none)
        XCTAssertEqual(RestoreDetailKind(detail: "AX cannot see window"), .axUnreachable)
        XCTAssertEqual(RestoreDetailKind(detail: "something with a Private Title"), .other)
    }

    func testLaunchEventCarriesVersionBuildAndOS() {
        let event = DiagnosticsEvent.appLaunchedDetail(
            version: "1.2", build: "34", osVersion: "Version 26.0", accessibilityTrusted: true,
            capability: .positionOnly(reason: "missing: x")
        )
        XCTAssertEqual(event.name, "app-launched")
        XCTAssertEqual(event.fields["version"], .string("1.2"))
        XCTAssertEqual(event.fields["build"], .string("34"))
        XCTAssertEqual(event.fields["os_version"], .string("Version 26.0"))
        XCTAssertEqual(event.fields["capability"], .string("position-only"))
    }
}
