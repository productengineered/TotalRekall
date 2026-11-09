import XCTest
@testable import TotalRekall

final class SnapshotFileTests: XCTestCase {
    func testWrittenJSONContainsV12FieldsAndRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SnapshotKey.make(panelSerials: ["builtin", "S123"])
        let win = WindowSnapshot(
            id: UUID(), bundleID: "com.apple.Safari", appName: "Safari", windowID: 4242, windowTitle: "t",
            windowIndex: 0, displayFingerprint: "fp", displayIndex: 1, panelSerial: "S123", spaceOrdinal: 2,
            spaceUUID: "u", spaceIndex: 3, frame: SnapshotFrame(x: -10, y: 5, width: 640, height: 480),
            isFullscreen: false, isMinimized: false, zOrder: 7)
        let display = DisplaySnapshot(
            vendorID: 1, productID: 2, serialNumber: "", panelSerial: "S123", unitNumber: 3,
            iokitLocationPath: nil, resolution: SnapshotSize(width: 100, height: 100), scaleFactor: 2,
            displayName: "D", originX: 0, originY: 0, isMain: true, cgDisplayID: 9)
        let config = DisplayConfigSnapshot(
            fingerprint: key, displayConfigName: "n", displays: [display],
            lastSnapshotDate: Date(timeIntervalSince1970: 1_700_000_000), windows: [win],
            spacesManifest: SpacesManifest(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), orderedSpaces: [
                SpaceEntry(panelSerial: "S123", ordinal: 2, displayFingerprint: "fp", indexOnDisplay: 1,
                           isFullscreen: false, spaceUUID: nil)]))
        let store = SnapshotStore(directory: dir)
        _ = try await store.save(config, key: key)

        let text = try String(contentsOf: store.snapshotURL, encoding: .utf8)
        for field in ["\"panelSerial\"", "\"spaceOrdinal\"", "\"windowID\"", "\"ordinal\"", "\"configurations\"", "\"version\""] {
            XCTAssertTrue(text.contains(field), "missing \(field)")
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.configurations[key], config)
        XCTAssertEqual(loaded.configurations[key]?.windows.first?.desktopKey, DesktopKey(panelSerial: "S123", ordinal: 2))
    }

    func testSnapshotKeyIsOrderIndependent() {
        XCTAssertEqual(SnapshotKey.make(panelSerials: ["a", "b"]), SnapshotKey.make(panelSerials: ["b", "a"]))
        XCTAssertNotEqual(SnapshotKey.make(panelSerials: ["a"]), SnapshotKey.make(panelSerials: ["a", "b"]))
    }

    func testPreV12FileDecodesWithNilOptionals() throws {
        let json = """
        {"bundleID":"x","appName":"X","windowTitle":"","windowIndex":0,"displayIndex":0,"spaceIndex":0,
         "frame":{"x":0,"y":0,"width":1,"height":1},"isFullscreen":false,"isMinimized":false,"zOrder":0,
         "id":"\(UUID().uuidString)"}
        """
        let w = try JSONDecoder().decode(WindowSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(w.windowID)
        XCTAssertNil(w.desktopKey)
    }
}
