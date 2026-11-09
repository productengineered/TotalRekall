import XCTest
@testable import TotalRekall

final class DesktopKeyTests: XCTestCase {
    private func shim(_ idx: Int, _ serial: String) -> String {
        "+-o IOMobileFramebufferShim  <class IOMobileFramebufferShim>\n"
            + "  | {\n  |   \"DCPIndex\" = \(idx)\n  |   \"DisplayAttributes\" = {\"ProductAttributes\"={\"AlphanumericSerialNumber\"=\"\(serial)\"}}\n  | }\n"
    }

    func testParseOrdersByDCPIndex() {
        let text = shim(2, "SER-B") + shim(0, "SER-A")
        XCTAssertEqual(PanelIdentity.parseDCPSerials(ioregText: text), ["SER-A", "SER-B"])
    }

    func testParseSkipsChunkWithoutSerial() {
        let text = "+-o IOMobileFramebufferShim\n  \"DCPIndex\" = 1\n" + shim(0, "SER-A")
        XCTAssertEqual(PanelIdentity.parseDCPSerials(ioregText: text), ["SER-A"])
    }

    func testPairBridgesNthUnitToNthIndex() {
        let displays = [
            DisplayIdentityInput(displayID: 1, unitNumber: 0, isBuiltin: true),
            DisplayIdentityInput(displayID: 20, unitNumber: 7, isBuiltin: false),
            DisplayIdentityInput(displayID: 10, unitNumber: 3, isBuiltin: false)
        ]
        let p = PanelIdentity.pair(displays: displays, serialsInDCPOrder: ["A", "B"])
        XCTAssertNil(p.note)
        XCTAssertEqual(p.serialByDisplayID[1], .builtin)
        XCTAssertEqual(p.serialByDisplayID[10], .panel("A"))
        XCTAssertEqual(p.serialByDisplayID[20], .panel("B"))
    }

    func testPairCountMismatchMarksUnavailable() {
        let displays = [DisplayIdentityInput(displayID: 10, unitNumber: 3, isBuiltin: false)]
        let p = PanelIdentity.pair(displays: displays, serialsInDCPOrder: [])
        XCTAssertNotNil(p.note)
        XCTAssertEqual(p.serialByDisplayID[10], .unavailable)
    }

    private let topology = [
        DisplaySpaces(serial: .panel("A"), spaces: [SpaceInfo(id64: 5, type: 0), SpaceInfo(id64: 6, type: 4), SpaceInfo(id64: 7, type: 0)]),
        DisplaySpaces(serial: .builtin, spaces: [SpaceInfo(id64: 9, type: 0)]),
        DisplaySpaces(serial: .unavailable, spaces: [SpaceInfo(id64: 11, type: 0)])
    ]

    func testKeyOrdinalSkipsNonUserSpaces() {
        XCTAssertEqual(SpaceTopology.key(of: 7, in: topology), .key(DesktopKey(panelSerial: "A", ordinal: 2)))
        XCTAssertEqual(SpaceTopology.key(of: 9, in: topology), .key(DesktopKey(panelSerial: "builtin", ordinal: 1)))
    }

    func testKeyNonUserUnavailableAndMissing() {
        XCTAssertEqual(SpaceTopology.key(of: 6, in: topology), .notUserSpace)
        XCTAssertEqual(SpaceTopology.key(of: 11, in: topology), .serialUnavailable)
        XCTAssertEqual(SpaceTopology.key(of: 99, in: topology), .spaceNotFound)
    }

    func testSpaceIDRoundTrip() {
        let key = DesktopKey(panelSerial: "A", ordinal: 2)
        XCTAssertEqual(SpaceTopology.spaceID(for: key, in: topology), 7)
        XCTAssertNil(SpaceTopology.spaceID(for: DesktopKey(panelSerial: "A", ordinal: 3), in: topology))
        XCTAssertNil(SpaceTopology.spaceID(for: DesktopKey(panelSerial: "ZZ", ordinal: 1), in: topology))
    }
}
