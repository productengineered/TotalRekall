import XCTest
@testable import TotalRekall

final class SpaceMoveProbeTests: XCTestCase {

    private struct FakeResolver: SpaceSymbolResolving {
        var classes: Set<String> = [SpaceBridgeProbe.moveClassName]
        var selectors: Set<String> = [SpaceBridgeProbe.initSelector, SpaceBridgeProbe.performSelector]
        var symbols: Set<String> = Set(SpaceBridgeProbe.requiredCSymbols + ["CGSMainConnectionID"])
        func classExists(_ name: String) -> Bool { classes.contains(name) }
        func instanceSelectorExists(className: String, selector: String) -> Bool { selectors.contains(selector) }
        func cSymbolExists(_ name: String) -> Bool { symbols.contains(name) }
    }

    private final class SpyAPI: SkyLightAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var spaceAfterMove: UInt64?
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private func bump() { lock.lock(); _calls += 1; lock.unlock() }
        func copyManagedDisplays() throws -> [SLSDisplay] { bump(); return [] }
        func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] {
            bump(); return spaceAfterMove.map { [$0] } ?? []
        }
        func submitMove(windowIDs: [CGWindowID], toSpaceID: UInt64) throws { bump() }
    }

    func testFullWhenEverythingResolves() {
        XCTAssertEqual(SpaceBridgeProbe.evaluate(using: FakeResolver()), .full)
    }

    func testMissingClassYieldsPositionOnly() {
        var resolver = FakeResolver(); resolver.classes = []
        guard case .positionOnly(let reason) = SpaceBridgeProbe.evaluate(using: resolver) else {
            return XCTFail("expected positionOnly")
        }
        XCTAssertTrue(reason.contains(SpaceBridgeProbe.moveClassName))
    }

    func testMissingSelectorYieldsPositionOnly() {
        var resolver = FakeResolver(); resolver.selectors = [SpaceBridgeProbe.initSelector]
        guard case .positionOnly(let reason) = SpaceBridgeProbe.evaluate(using: resolver) else {
            return XCTFail("expected positionOnly")
        }
        XCTAssertTrue(reason.contains(SpaceBridgeProbe.performSelector))
    }

    func testMissingAXJoinSymbolYieldsPositionOnly() {
        var resolver = FakeResolver(); resolver.symbols.remove("_AXUIElementGetWindow")
        guard case .positionOnly(let reason) = SpaceBridgeProbe.evaluate(using: resolver) else {
            return XCTFail("expected positionOnly")
        }
        XCTAssertTrue(reason.contains("_AXUIElementGetWindow"))
    }

    func testMissingConnectionSymbolYieldsPositionOnly() {
        var resolver = FakeResolver(); resolver.symbols.remove("CGSMainConnectionID")
        XCTAssertNotEqual(SpaceBridgeProbe.evaluate(using: resolver), .full)
    }

    func testAlternateConnectionSymbolAccepted() {
        var resolver = FakeResolver(); resolver.symbols.remove("CGSMainConnectionID"); resolver.symbols.insert("SLSMainConnectionID")
        XCTAssertEqual(SpaceBridgeProbe.evaluate(using: resolver), .full)
    }

    func testPositionOnlyMakesZeroPrivateCalls() async {
        var resolver = FakeResolver(); resolver.classes = []
        let spy = SpyAPI()
        let bridge = SpaceBridge(resolver: resolver, api: spy)
        do {
            try await bridge.moveWindows([1, 2], toSpaceID: 9)
            XCTFail("expected throw")
        } catch let error as SpaceBridgeError {
            guard case .positionOnlyMode = error else { return XCTFail("wrong error \(error)") }
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(spy.calls, 0)
    }

    func testFullModeSubmitsAndConfirms() async throws {
        let spy = SpyAPI(); spy.spaceAfterMove = 9
        let bridge = SpaceBridge(resolver: FakeResolver(), api: spy, pollIntervalMS: 1, timeoutMS: 50)
        try await bridge.moveWindows([1], toSpaceID: 9)
        XCTAssertGreaterThanOrEqual(spy.calls, 2)
    }

    func testUnconfirmedMoveTimesOut() async {
        let spy = SpyAPI(); spy.spaceAfterMove = 3
        let bridge = SpaceBridge(resolver: FakeResolver(), api: spy, pollIntervalMS: 1, timeoutMS: 10)
        do {
            try await bridge.moveWindows([1], toSpaceID: 9)
            XCTFail("expected throw")
        } catch let error as SpaceBridgeError {
            XCTAssertEqual(error, .moveNotConfirmed(timeoutMS: 10))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testLiveProbeDoesNotCrash() {
        // On the author's Mac this is .full; elsewhere positionOnly. Either is valid, neither may crash.
        switch SpaceBridgeProbe.evaluate(using: LiveSpaceSymbolResolver()) {
        case .full: break
        case .positionOnly(let reason): XCTAssertFalse(reason.isEmpty)
        }
    }
}
