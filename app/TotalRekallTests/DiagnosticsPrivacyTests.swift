import XCTest
@testable import TotalRekall

final class DiagnosticsPrivacyTests: XCTestCase {
    private struct FakeWindow { let title: String; let id: Int }

    func testEventBuiltFromWindowWritesNoTitleBytes() async throws {
        let sentinel = "SENTINEL-SECRET-TITLE-\(UUID().uuidString)"
        let windows = [FakeWindow(title: sentinel, id: 1), FakeWindow(title: sentinel, id: 2)]
        let event = DiagnosticsEvent.snapshotSaved(cycleID: UUID(), windowCount: windows.count, desktopCount: 1)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = DiagnosticsFileSink(directory: dir)
        await sink.write(DiagnosticsRecord(ts: "t", seq: 1, pid: 1, event: event))
        let data = try Data(contentsOf: sink.fileURL(index: 0))
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: sentinel))
    }

    func testEventHasNoTitleLikeField() {
        let names = Mirror(reflecting: DiagnosticsEvent(.snapshot, "x")).children.compactMap(\.label)
        XCTAssertEqual(Set(names), ["category", "name", "cycleID", "fields"])
        XCTAssertFalse(names.contains { $0.lowercased().contains("title") })
    }

    func testWindowResultKeepsTitleAndAppIdentityOutOfPublicLogAndFile() async throws {
        let sentinel = "SENTINEL-SECRET-TITLE-\(UUID().uuidString)"
        let bundleID = "com.example.sentinel-\(UUID().uuidString)"
        let appName = "SentinelApp-\(UUID().uuidString)"
        let result = RestoreWindowResult(snapshotID: UUID(), windowID: 7, bundleID: bundleID, appName: appName,
                                         title: sentinel, status: .moved)
        let event = DiagnosticsEvent.windowResult(cycleID: UUID(), result: result, desktop: nil)

        let parts = DiagnosticsLog.summaryParts(event)
        XCTAssertNil(parts.publicText.range(of: sentinel))
        XCTAssertNil(parts.privateText.range(of: sentinel))
        XCTAssertNil(parts.publicText.range(of: bundleID))
        XCTAssertNil(parts.publicText.range(of: appName))
        XCTAssertNotNil(parts.privateText.range(of: bundleID))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = DiagnosticsFileSink(directory: dir)
        await sink.write(DiagnosticsRecord(ts: "t", seq: 1, pid: 1, event: event))
        let text = String(decoding: try Data(contentsOf: sink.fileURL(index: 0)), as: UTF8.self)
        XCTAssertNil(text.range(of: sentinel))
        XCTAssertNotNil(text.range(of: bundleID))
    }
}
