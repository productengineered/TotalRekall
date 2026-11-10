import XCTest
@testable import TotalRekall

final class RestoreLogTriggerTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    private func makeLog(context: CycleContext?) -> RestoreLog {
        RestoreLog(results: [], date: date, configKey: nil, capability: .full, layout: nil, context: context)
    }

    func testAutomaticRunLogEncodesTriggerAndCycleID() throws {
        let context = CycleContext(trigger: .wake, cycleID: UUID(), startedAt: date)
        let data = try JSONEncoder().encode(makeLog(context: context))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["trigger"] as? String, "wake")
        XCTAssertEqual(json["cycleID"] as? String, context.cycleID.uuidString)
    }

    func testTriggerRawValuesAreStable() {
        XCTAssertEqual(CycleTrigger.allCases.map(\.rawValue), ["display-change", "wake", "launch", "manual"])
    }

    func testTR200EraLogWithoutTriggerOrCycleIDStillDecodes() throws {
        let data = try JSONEncoder().encode(makeLog(context: CycleContext(trigger: .manual, startedAt: date)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "trigger")
        json.removeValue(forKey: "cycleID")
        json.removeValue(forKey: "monitorFix")
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RestoreLog.self, from: old)
        XCTAssertNil(decoded.trigger)
        XCTAssertNil(decoded.cycleID)
    }

    func testLogRoundTripsThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestoreLogStore(directory: dir)
        let context = CycleContext(trigger: .displayChange, startedAt: date)
        try store.write(makeLog(context: context))
        let loaded = try store.load()
        XCTAssertEqual(loaded.trigger, .displayChange)
        XCTAssertEqual(loaded.cycleID, context.cycleID)
    }
}

// MARK: - Desk name (named desks)

final class RestoreLogDeskNameTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    func testDeskNameIsWrittenNextToTheConfigKey() throws {
        let log = RestoreLog(results: [], date: date, configKey: "cfg", capability: .full, layout: nil,
                             deskName: "Studio")
        let data = try JSONEncoder().encode(log)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["deskName"] as? String, "Studio")
        XCTAssertEqual(json["configKey"] as? String, "cfg")
        XCTAssertNotNil(json["capability"])
        XCTAssertNotNil(json["counts"])
    }

    func testLogWithoutDeskNameStillDecodes() throws {
        let log = RestoreLog(results: [], date: date, configKey: "cfg", capability: .full, layout: nil,
                             deskName: "Studio")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        json.removeValue(forKey: "deskName")
        let decoded = try JSONDecoder().decode(RestoreLog.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.deskName)
        XCTAssertEqual(decoded.configKey, "cfg")
    }

    func testDeskNameRoundTripsAndReachesTheLastRestoreDetail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RestoreLogStore(directory: dir)
        try store.write(RestoreLog(results: [], date: date, configKey: nil, capability: .full, layout: nil,
                                   deskName: "Studio"))
        let loaded = try store.load()
        XCTAssertEqual(loaded.deskName, "Studio")
        XCTAssertEqual(RestoreDetailFormatter.detail(from: loaded).deskName, "Studio")
    }
}
