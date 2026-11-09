import XCTest
@testable import TotalRekall

final class DiagnosticsLogTests: XCTestCase {
    private actor StalledSink: DiagnosticsSink {
        private(set) var written = 0
        func write(_ record: DiagnosticsRecord) async {
            written += 1
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func testRecordDoesNotBlockCaller() {
        let log = DiagnosticsLog(sink: StalledSink())
        let start = ContinuousClock.now
        for _ in 0..<200 { log.record(DiagnosticsEvent(.lifecycle, "tick")) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testRecordWithSinkOffIsHarmless() {
        DiagnosticsLog().record(DiagnosticsEvent(.snapshot, "snapshot-failed"))
    }

    func testSequenceIncreasesAndEventsReachSink() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = DiagnosticsFileSink(directory: dir)
        let log = DiagnosticsLog(sink: sink)
        log.record(.appLaunched(version: "1.0"))
        log.record(.appTerminating())
        let url = sink.fileURL(index: 0)
        var lines: [String] = []
        for _ in 0..<100 {
            lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            if lines.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(lines.count, 2)
        let seqs = try lines.map { line -> Int in
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(obj["seq"] as? Int)
        }
        XCTAssertEqual(seqs, [1, 2])
    }

    func testRecordingDiagnosticsCapturesEvents() {
        let rec = RecordingDiagnostics()
        rec.record(.exportCompleted(fileCount: 3))
        XCTAssertEqual(rec.events.map(\.name), ["export-completed"])
    }
}
