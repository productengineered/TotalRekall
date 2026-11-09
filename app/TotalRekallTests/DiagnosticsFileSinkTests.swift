import XCTest
@testable import TotalRekall

final class DiagnosticsFileSinkTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        super.tearDown()
    }

    private func record(_ seq: UInt64, padding: Int = 0) -> DiagnosticsRecord {
        DiagnosticsRecord(ts: "2026-01-01T00:00:00.000Z", seq: seq, pid: 1,
                          event: DiagnosticsEvent(.lifecycle, "test-event",
                                                  fields: ["pad": .string(String(repeating: "x", count: padding))]))
    }

    func testRotatesPastLimitAndKeepsAtMostThreeFiles() async throws {
        let sink = DiagnosticsFileSink(directory: dir)
        // ~1 MB lines: 16 writes ~ 16 MB forces several rotations.
        for i in 0..<16 { await sink.write(record(UInt64(i), padding: 1_000_000)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["diagnostics.1.jsonl", "diagnostics.2.jsonl", "diagnostics.jsonl"])
        for i in 0..<3 {
            let size = try FileManager.default.attributesOfItem(atPath: sink.fileURL(index: i).path)[.size] as? Int
            XCTAssertLessThanOrEqual(size ?? .max, DiagnosticsFileSink.maxFileBytes)
        }
    }

    func testFolderIs0700AndFilesAre0600() async throws {
        let sink = DiagnosticsFileSink(directory: dir)
        await sink.write(record(1))
        let dirPerm = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        let filePerm = try FileManager.default.attributesOfItem(atPath: sink.fileURL(index: 0).path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerm, 0o700)
        XCTAssertEqual(filePerm, 0o600)
    }

    func testLineIsJSONWithExpectedKeys() async throws {
        let sink = DiagnosticsFileSink(directory: dir)
        await sink.write(record(7))
        let text = try String(contentsOf: sink.fileURL(index: 0), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        for key in ["ts", "seq", "pid", "category", "event", "cycleID", "fields"] {
            XCTAssertNotNil(obj[key], key)
        }
        XCTAssertEqual(obj["event"] as? String, "test-event")
    }

    func testWriteFailureDoesNotThrowOrCrash() async {
        let blocker = dir.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.path, contents: Data())  // a file where the folder should be
        let sink = DiagnosticsFileSink(directory: dir)
        await sink.write(record(1))
        await sink.write(record(2))
    }
}
