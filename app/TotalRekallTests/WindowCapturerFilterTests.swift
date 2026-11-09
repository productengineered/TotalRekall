import CoreGraphics
import Synchronization
import XCTest
@testable import TotalRekall

final class WindowCapturerFilterTests: XCTestCase {

    // MARK: Fixtures shaped like CGWindowListCopyWindowInfo output

    private func raw(id: Int, pid: Int = 100, owner: String = "Safari", title: String? = "Tab",
                     layer: Int = 0, alpha: Double = 1, onScreen: Bool = true,
                     x: Int = 0, y: Int = 0, w: Int = 800, h: Int = 600) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowOwnerPID as String: pid,
            kCGWindowNumber as String: id,
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowIsOnscreen as String: onScreen,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]
        ]
        if let title { d[kCGWindowName as String] = title }
        return d
    }

    private func info(_ dict: [String: Any], bundle: String? = "com.apple.Safari") -> CGWindowInfo {
        WindowCapturer.parse(dict) { _ in bundle }!
    }

    private let builtin = LiveDisplay(
        displayID: 1, serial: .builtin, frame: SnapshotFrame(x: 0, y: 0, width: 1512, height: 982),
        pixelSize: SnapshotSize(width: 3024, height: 1964), scaleFactor: 2, name: "Built-in",
        vendorID: 0, productID: 0, serialNumber: "", unitNumber: 0, isMain: true)
    private let external = LiveDisplay(
        displayID: 2, serial: .panel("EXT123"), frame: SnapshotFrame(x: 1512, y: -200, width: 2560, height: 1440),
        pixelSize: SnapshotSize(width: 5120, height: 2880), scaleFactor: 2, name: "Ext",
        vendorID: 0, productID: 0, serialNumber: "", unitNumber: 1, isMain: false)

    private var topology: [DisplaySpaces] {
        [DisplaySpaces(serial: .builtin, spaces: [SpaceInfo(id64: 10, type: 0), SpaceInfo(id64: 11, type: 0), SpaceInfo(id64: 12, type: 4)]),
         DisplaySpaces(serial: .panel("EXT123"), spaces: [SpaceInfo(id64: 20, type: 0), SpaceInfo(id64: 21, type: 0)])]
    }

    private func assemble(_ windows: [CGWindowInfo], ax: [UInt32: AXWindowState], spaces: [UInt32: [UInt64]]) -> [WindowSnapshot] {
        WindowCapturer.assemble(windows: windows, axStates: ax, spaceIDs: spaces,
                                displays: [builtin, external], topology: topology, fingerprint: "fp")
    }

    // MARK: Parsing

    func testParseReadsFieldsAndAcceptsIntOrDoubleBounds() throws {
        let w = info(raw(id: 7, x: 12, y: 34, w: 640, h: 480))
        XCTAssertEqual(w.windowID, 7)
        XCTAssertEqual(w.ownerPID, 100)
        XCTAssertEqual(w.frame, SnapshotFrame(x: 12, y: 34, width: 640, height: 480))
        XCTAssertEqual(w.title, "Tab")
        XCTAssertTrue(w.onScreen)
    }

    func testParseRejectsMissingRequiredKeys() {
        var d = raw(id: 1)
        d[kCGWindowBounds as String] = nil
        XCTAssertNil(WindowCapturer.parse(d) { _ in "x" })
    }

    // MARK: Filtering

    func testNonZeroLayerDropped() {
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 1, layer: 25))))
    }

    func testTinyAndZeroSizeDropped() {
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 1, w: 0, h: 0))))
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 2, w: 99, h: 600))))
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 3, w: 800, h: 49))))
    }

    func testAlphaZeroDropped() {
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 1, alpha: 0))))
    }

    func testNoBundleIDDropped() {
        XCTAssertFalse(WindowCapturer.isCandidate(info(raw(id: 1), bundle: nil)))
    }

    func testUntitledUnmatchedDroppedButUntitledAXMatchedKept() {
        let w = info(raw(id: 1, title: nil))
        XCTAssertFalse(WindowCapturer.isRestorable(w, axMatched: false))
        XCTAssertTrue(WindowCapturer.isRestorable(w, axMatched: true))
        XCTAssertTrue(WindowCapturer.isRestorable(info(raw(id: 2, title: "Doc")), axMatched: false))
    }

    // MARK: Assembly

    func testMatchesAXByWindowIDNotIndex() {
        let a = info(raw(id: 5, title: nil)), b = info(raw(id: 6, title: nil))
        // Only window 6 is AX-visible; window 5 (untitled) must drop even though it comes first.
        let out = assemble([a, b], ax: [6: AXWindowState(minimized: false, fullscreen: false)], spaces: [6: [10]])
        XCTAssertEqual(out.map(\.windowID), [6])
    }

    func testDesktopKeyAndMonitorFromSpace() throws {
        let out = assemble([info(raw(id: 1)), info(raw(id: 2, x: 1600, y: 0))],
                           ax: [1: .init(), 2: .init()], spaces: [1: [11], 2: [21]])
        XCTAssertEqual(out[0].desktopKey, DesktopKey(panelSerial: "builtin", ordinal: 2))
        XCTAssertEqual(out[1].desktopKey, DesktopKey(panelSerial: "EXT123", ordinal: 2))
        XCTAssertEqual(out[0].displayIndex, 0)
        XCTAssertEqual(out[1].displayIndex, 1)
        XCTAssertEqual(out[0].sticky, false)
        XCTAssertEqual(out[0].axVisible, true)
    }

    func testStickyWindowMarkedAndHasNoDesktopKey() {
        let out = assemble([info(raw(id: 1, x: 1600, y: 0))], ax: [1: .init()], spaces: [1: [10, 20, 10]])
        XCTAssertEqual(out[0].sticky, true)
        XCTAssertNil(out[0].desktopKey)
        XCTAssertEqual(out[0].panelSerial, "EXT123")  // by frame center
    }

    func testMinimizedAndFullscreenHaveSeparateSkipReasons() {
        let out = assemble([info(raw(id: 1)), info(raw(id: 2)), info(raw(id: 3))],
                           ax: [1: AXWindowState(minimized: true, fullscreen: false),
                                2: AXWindowState(minimized: false, fullscreen: true),
                                3: AXWindowState(minimized: false, fullscreen: false)],
                           spaces: [1: [10], 2: [10], 3: [10]])
        XCTAssertEqual(out.map(\.skipReason), [.minimized, .fullscreen, nil])
        XCTAssertEqual(out.map(\.isMinimized), [true, false, false])
        XCTAssertEqual(out.map(\.isFullscreen), [false, true, false])
    }

    func testFullscreenSpaceImpliesFullscreenSkipWithNoOrdinal() {
        let out = assemble([info(raw(id: 1))], ax: [1: .init()], spaces: [1: [12]])
        XCTAssertEqual(out[0].skipReason, .fullscreen)
        XCTAssertNil(out[0].spaceOrdinal)
        XCTAssertEqual(out[0].panelSerial, "builtin")
    }

    func testOffDesktopWindowRecordedFromCGPlusSLSWithAXVisibleFalse() {
        // Titled window on another desktop: AX cannot see it, so it is kept from CG + SLS only.
        let out = assemble([info(raw(id: 1, title: "Elsewhere", onScreen: false))], ax: [:], spaces: [1: [20]])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].axVisible, false)
        XCTAssertEqual(out[0].desktopKey, DesktopKey(panelSerial: "EXT123", ordinal: 1))
        XCTAssertNil(out[0].skipReason)
    }

    func testPerAppWindowIndexAndZOrder() {
        let out = assemble([info(raw(id: 1)), info(raw(id: 2))], ax: [1: .init(), 2: .init()], spaces: [:])
        XCTAssertEqual(out.map(\.windowIndex), [0, 1])
        XCTAssertEqual(out.map(\.zOrder), [0, 1])
    }

    func testLayoutMapsSerialToOrigin() {
        let layout = MonitorLayout.from(displays: [builtin, external])
        XCTAssertEqual(layout.origins["builtin"], .init(x: 0, y: 0))
        XCTAssertEqual(layout.origins["EXT123"], .init(x: 1512, y: -200))
    }

    func testLayoutOmitsUnavailableSerial() {
        let bad = LiveDisplay(displayID: 3, serial: .unavailable, frame: external.frame, pixelSize: external.pixelSize,
                              scaleFactor: 2, name: "x", vendorID: 0, productID: 0, serialNumber: "", unitNumber: 2, isMain: false)
        XCTAssertEqual(MonitorLayout.from(displays: [builtin, bad]).origins.count, 1)
    }
}

// MARK: - SnapshotService failure paths

/// Token from a fresh, open SnapshotGate (no display change in these tests).
private var openGate: SnapshotGateToken { SnapshotGateToken(gate: SnapshotGate(), epoch: 0) }

final class SnapshotServiceTests: XCTestCase {
    private struct Trust: AccessibilityTrustChecking { let trusted: Bool; func isProcessTrusted() -> Bool { trusted } }
    private struct Windows: WindowListProviding { func windowList() -> [CGWindowInfo] { [] } }
    private struct AX: AXWindowProbing {
        var isAvailable = true
        func states(pid: Int32) -> [UInt32: AXWindowState] { [:] }
    }
    private struct NoDisplays: DisplayProviding { func currentDisplays() -> [LiveDisplay] { [] } }

    private struct StubResolver: SpaceSymbolResolving {
        func classExists(_ name: String) -> Bool { false }
        func instanceSelectorExists(className: String, selector: String) -> Bool { false }
        func cSymbolExists(_ name: String) -> Bool { false }
    }
    private struct StubAPI: SkyLightAPI {
        func copyManagedDisplays() throws -> [SLSDisplay] { [] }
        func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] { [] }
        func submitMove(windowIDs: [CGWindowID], toSpaceID: UInt64) throws {}
    }

    func testAccessibilityRevokedFailsAndWritesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        let service = SnapshotService(
            store: store, bridge: SpaceBridge(resolver: StubResolver(), api: StubAPI()),
            trust: Trust(trusted: false), windowList: Windows(), axProbe: AX(), displayProvider: NoDisplays())
        do {
            _ = try await service.capture(reason: .manual, gate: openGate)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? SnapshotCaptureError, .accessibilityNotGranted)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    func testMissingAXJoinFails() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = SnapshotService(
            store: SnapshotStore(directory: dir), bridge: SpaceBridge(resolver: StubResolver(), api: StubAPI()),
            trust: Trust(trusted: true), windowList: Windows(), axProbe: AX(isAvailable: false), displayProvider: NoDisplays())
        do { _ = try await service.capture(reason: .manual, gate: openGate); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? SnapshotCaptureError, .axWindowJoinUnavailable)
        }
    }

    func testNoDisplaysFails() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = SnapshotService(
            store: SnapshotStore(directory: dir), bridge: SpaceBridge(resolver: StubResolver(), api: StubAPI()),
            trust: Trust(trusted: true), windowList: Windows(), axProbe: AX(), displayProvider: NoDisplays())
        do { _ = try await service.capture(reason: .manual, gate: openGate); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? SnapshotCaptureError, .noDisplays)
        }
    }
}

// MARK: - SnapshotService success + guard wiring (stub providers)

final class SnapshotServiceCaptureTests: XCTestCase {
    private struct Trust: AccessibilityTrustChecking { func isProcessTrusted() -> Bool { true } }
    private struct Windows: WindowListProviding {
        let list: [CGWindowInfo]
        func windowList() -> [CGWindowInfo] { list }
    }
    private struct AX: AXWindowProbing {
        var isAvailable = true
        func states(pid: Int32) -> [UInt32: AXWindowState] { [1: AXWindowState(), 2: AXWindowState()] }
    }
    private struct Displays: DisplayProviding {
        let list: [LiveDisplay]
        func currentDisplays() -> [LiveDisplay] { list }
    }
    private struct Resolver: SpaceSymbolResolving {
        func classExists(_ name: String) -> Bool { true }
        func instanceSelectorExists(className: String, selector: String) -> Bool { true }
        func cSymbolExists(_ name: String) -> Bool { true }
    }
    private struct API: SkyLightAPI {
        var failSpaces = false
        func copyManagedDisplays() throws -> [SLSDisplay] {
            [SLSDisplay(identifier: "Main", spaces: [SpaceInfo(id64: 10, type: 0)], currentSpaceID: 10)]
        }
        func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] {
            if failSpaces { throw SpaceBridgeError.topologyUnavailable }
            return [10]
        }
        func submitMove(windowIDs: [CGWindowID], toSpaceID: UInt64) throws {}
    }

    private func display(serial: PanelIdentity.Serial) -> LiveDisplay {
        LiveDisplay(displayID: CGMainDisplayID(), serial: serial, frame: SnapshotFrame(x: 0, y: 0, width: 1512, height: 982),
                    pixelSize: SnapshotSize(width: 3024, height: 1964), scaleFactor: 2, name: "Built-in",
                    vendorID: 0, productID: 0, serialNumber: "", unitNumber: 0, isMain: true)
    }

    private func win(_ id: UInt32) -> CGWindowInfo {
        CGWindowInfo(windowID: id, ownerPID: 100, ownerName: "Safari", bundleID: "com.apple.Safari", title: "Tab \(id)",
                     frame: SnapshotFrame(x: 0, y: 0, width: 800, height: 600), layer: 0, alpha: 1, onScreen: true)
    }

    private func makeService(dir: URL, windows: [CGWindowInfo], displays: [LiveDisplay],
                             api: API = API()) -> (SnapshotService, SnapshotStore) {
        let store = SnapshotStore(directory: dir)
        let service = SnapshotService(
            store: store, bridge: SpaceBridge(resolver: Resolver(), api: api), trust: Trust(),
            windowList: Windows(list: windows), axProbe: AX(), displayProvider: Displays(list: displays))
        return (service, store)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotServiceCaptureTests-\(UUID().uuidString)")
    }

    func testSuccessfulCaptureWritesExpectedKeyLayoutAndCount() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (service, store) = makeService(dir: dir, windows: [win(1), win(2)], displays: [display(serial: .builtin)])
        let result = try await service.capture(reason: .manual, gate: openGate)
        XCTAssertEqual(result.outcome, .written)
        XCTAssertEqual(result.windowCount, 2)
        XCTAssertEqual(result.configKey, SnapshotKey.make(panelSerials: ["builtin"]))
        XCTAssertEqual(result.layout.origins["builtin"], .init(x: 0, y: 0))
        let file = try await store.load()
        XCTAssertEqual(file.configurations[result.configKey]?.windows.count, 2)
    }

    func testUnreadablePanelSerialFailsAndWritesNothing() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (service, store) = makeService(dir: dir, windows: [win(1)], displays: [display(serial: .unavailable)])
        do { _ = try await service.capture(reason: .manual, gate: openGate); XCTFail("expected failure") } catch {
            XCTAssertEqual(error as? SnapshotCaptureError, .panelIdentityUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    func testSpaceLookupFailureThrowsTopologyUnavailableAndWritesNothing() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (service, store) = makeService(dir: dir, windows: [win(1)], displays: [display(serial: .builtin)],
                                           api: API(failSpaces: true))
        do { _ = try await service.capture(reason: .manual, gate: openGate); XCTFail("expected failure") } catch {
            guard case .topologyUnavailable = error as? SnapshotCaptureError else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL.path))
    }

    func testZeroWindowCapturePropagatesSkippedZeroWindows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let displays = [display(serial: .builtin)]
        let (first, store) = makeService(dir: dir, windows: [win(1), win(2)], displays: displays)
        _ = try await first.capture(reason: .manual, gate: openGate)
        let before = try Data(contentsOf: store.snapshotURL)
        let (second, _) = makeService(dir: dir, windows: [], displays: displays)
        let result = try await second.capture(reason: .periodic, gate: openGate)
        XCTAssertEqual(result.outcome, .skippedZeroWindows(priorCount: 2))
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), before)
    }
}

// MARK: - Capture trust guards (Bug 65: locked session, screens asleep)

/// The locked-session capture shape: other apps' windows have no CG title and AX returns nothing for
/// any pid, while CG still titles Total Rekall's own window.
final class SnapshotTrustGuardTests: XCTestCase {
    private static let ownPID: Int32 = 999
    private static let lockedAXError: Int32 = -25204  // kAXErrorCannotComplete

    private struct Trust: AccessibilityTrustChecking { func isProcessTrusted() -> Bool { true } }
    private struct Windows: WindowListProviding {
        let list: [CGWindowInfo]
        func windowList() -> [CGWindowInfo] { list }
    }
    /// AX either joins every listed window (unlocked) or returns nothing with an error (locked).
    private struct AX: AXWindowProbing {
        let locked: Bool
        let windowsByPID: [Int32: [UInt32]]
        var isAvailable: Bool { true }
        func states(pid: Int32) -> [UInt32: AXWindowState] { probe(pid: pid).states }
        func probe(pid: Int32) -> AXProbeResult {
            if locked { return AXProbeResult(states: [:], errorCode: SnapshotTrustGuardTests.lockedAXError) }
            let ids = windowsByPID[pid] ?? []
            return AXProbeResult(states: Dictionary(uniqueKeysWithValues: ids.map { ($0, AXWindowState()) }), errorCode: nil)
        }
    }
    private struct Displays: DisplayProviding {
        func currentDisplays() -> [LiveDisplay] {
            [LiveDisplay(displayID: CGMainDisplayID(), serial: .builtin,
                         frame: SnapshotFrame(x: 0, y: 0, width: 1512, height: 982),
                         pixelSize: SnapshotSize(width: 3024, height: 1964), scaleFactor: 2, name: "Built-in",
                         vendorID: 0, productID: 0, serialNumber: "", unitNumber: 0, isMain: true)]
        }
    }
    private struct Resolver: SpaceSymbolResolving {
        func classExists(_ name: String) -> Bool { true }
        func instanceSelectorExists(className: String, selector: String) -> Bool { true }
        func cSymbolExists(_ name: String) -> Bool { true }
    }
    private struct API: SkyLightAPI {
        func copyManagedDisplays() throws -> [SLSDisplay] {
            [SLSDisplay(identifier: "Main", spaces: [SpaceInfo(id64: 10, type: 0)], currentSpaceID: 10)]
        }
        func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] { [10] }
        func submitMove(windowIDs: [CGWindowID], toSpaceID: UInt64) throws {}
    }

    /// 41 untitled windows across 18 other apps plus one titled own window (the incident's shape).
    private var deskWindows: [CGWindowInfo] {
        var list = (0..<41).map { n in
            CGWindowInfo(windowID: UInt32(1000 + n), ownerPID: Int32(200 + n % 18), ownerName: "App\(n % 18)",
                         bundleID: "com.example.app\(n % 18)", title: nil,
                         frame: SnapshotFrame(x: 0, y: 0, width: 800, height: 600), layer: 0, alpha: 1, onScreen: true)
        }
        list.append(CGWindowInfo(windowID: 158_216, ownerPID: Self.ownPID, ownerName: "Total Rekall",
                                 bundleID: "com.productengineered.TotalRekall", title: "Total Rekall",
                                 frame: SnapshotFrame(x: 0, y: 0, width: 600, height: 400), layer: 0, alpha: 1,
                                 onScreen: true))
        return list
    }

    private func service(store: SnapshotStore, locked: Bool) -> SnapshotService {
        var byPID: [Int32: [UInt32]] = [:]
        for w in deskWindows { byPID[w.ownerPID, default: []].append(w.windowID) }
        return SnapshotService(store: store, bridge: SpaceBridge(resolver: Resolver(), api: API()), trust: Trust(),
                               windowList: Windows(list: deskWindows), axProbe: AX(locked: locked, windowsByPID: byPID),
                               displayProvider: Displays(), ownerPID: Self.ownPID)
    }

    private var openToken: SnapshotGateToken { SnapshotGateToken(gate: SnapshotGate(), epoch: 0) }

    func testOwnWindowIsNeverACandidateEvenWhenTitled() {
        let own = CGWindowInfo(windowID: 1, ownerPID: 42, ownerName: "Total Rekall", bundleID: "com.productengineered.TotalRekall",
                               title: "Total Rekall", frame: SnapshotFrame(x: 0, y: 0, width: 600, height: 400),
                               layer: 0, alpha: 1, onScreen: true)
        XCTAssertTrue(WindowCapturer.isCandidate(own))
        XCTAssertFalse(WindowCapturer.isCandidate(own, excludingOwnerPID: 42))
    }

    func testAXJoinCollapsedPredicate() {
        let other = deskWindows[0]
        let own = deskWindows[41]
        XCTAssertTrue(WindowCapturer.axJoinCollapsed(candidates: [other], axStates: [:], ownerPID: Self.ownPID))
        XCTAssertFalse(WindowCapturer.axJoinCollapsed(candidates: [other], axStates: [other.windowID: AXWindowState()],
                                                      ownerPID: Self.ownPID))
        XCTAssertFalse(WindowCapturer.axJoinCollapsed(candidates: [own], axStates: [:], ownerPID: Self.ownPID),
                       "only own windows: nothing to judge")
        XCTAssertFalse(WindowCapturer.axJoinCollapsed(candidates: [], axStates: [:], ownerPID: Self.ownPID))
    }

    func testUnlockedCaptureExcludesOwnWindowAndRecordsJoinCounts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrustGuard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await service(store: SnapshotStore(directory: dir), locked: false)
            .capture(reason: .periodic, gate: openToken)
        XCTAssertEqual(result.windowCount, 41)
        XCTAssertEqual(result.join, CaptureJoinStats(candidates: 41, axJoined: 41, firstAXError: nil))
    }

    /// Covers every capture reason that shares the path: periodic, launch (periodic tick 1),
    /// display-change resume, sleep, quit and manual.
    func testLockedCaptureThrowsAndLeavesStoreBytesUnchanged() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrustGuard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        _ = try await service(store: store, locked: false).capture(reason: .periodic, gate: openToken)
        let before = try Data(contentsOf: store.snapshotURL)

        for reason in [SnapshotReason.periodic, .displayChange, .sleep, .quit, .manual] {
            do {
                _ = try await service(store: store, locked: true).capture(reason: reason, gate: openToken)
                XCTFail("expected axJoinCollapsed for \(reason)")
            } catch {
                XCTAssertEqual(error as? SnapshotCaptureError,
                               .axJoinCollapsed(CaptureJoinStats(candidates: 41, axJoined: 0, firstAXError: Self.lockedAXError)))
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lastGoodURL.path))
    }

    // MARK: Coordinator trail + manual messages

    private struct ThrowingCapturer: SnapshotCapturing {
        let error: SnapshotCaptureError
        func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
            throw error
        }
    }

    private struct ZeroCapturer: SnapshotCapturing {
        func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
            SnapshotCaptureResult(reason: reason, outcome: .skippedZeroWindows(priorCount: 42),
                                  layout: MonitorLayout(origins: [:]), configKey: "k", windowCount: 0,
                                  join: CaptureJoinStats(candidates: 0, axJoined: 0, firstAXError: nil))
        }
    }

    func testCollapsedJoinRecordsSnapshotFailedWithCountsAndFriendlyManualMessage() async {
        let diag = RecordingDiagnostics()
        let join = CaptureJoinStats(candidates: 41, axJoined: 0, firstAXError: Self.lockedAXError)
        let coord = SnapshotCoordinator(capturer: ThrowingCapturer(error: .axJoinCollapsed(join)), gate: SnapshotGate(),
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: diag)
        await coord.runScheduledSnapshot()
        let manual = await coord.saveManually()

        XCTAssertEqual(manual, .refused(message: SnapshotCaptureError.axJoinCollapsed(join).menuMessage ?? ""))
        XCTAssertNotNil(SnapshotCaptureError.axJoinCollapsed(join).menuMessage)
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-failed", "snapshot-failed"])
        let fields = diag.events[0].fields
        XCTAssertEqual(fields["reason"], .string("ax-join-collapsed"))
        XCTAssertEqual(fields["candidates"], .int(41))
        XCTAssertEqual(fields["axJoined"], .int(0))
        XCTAssertEqual(fields["axError"], .int(Int(Self.lockedAXError)))
        XCTAssertEqual(fields["trigger"], .string("periodic"))
    }

    func testManualSaveOfZeroWindowsIsARefusalNotASave() async {
        let coord = SnapshotCoordinator(capturer: ZeroCapturer(), gate: SnapshotGate(),
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: RecordingDiagnostics())
        let manual = await coord.saveManually()
        XCTAssertEqual(manual, .refused(message: SnapshotCoordinator.zeroWindowsMessage))
    }
}

// MARK: - Shrink confirmation wiring (Bug 65)

extension SnapshotServiceCaptureTests {
    /// Scheduled/launch/display-change captures hold an under-half shrink; Save Snapshot Now accepts it.
    func testPeriodicShrinkIsHeldButManualShrinkIsAccepted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let displays = [display(serial: .builtin)]
        let (full, store) = makeService(dir: dir, windows: [win(1), win(2), win(3), win(4)], displays: displays)
        _ = try await full.capture(reason: .periodic, gate: openGate)
        let before = try Data(contentsOf: store.snapshotURL)

        let (shrunk, _) = makeService(dir: dir, windows: [win(1)], displays: displays)
        for reason in [SnapshotReason.periodic, .displayChange] {
            let held = try await shrunk.capture(reason: reason, gate: openGate)
            XCTAssertEqual(held.outcome, .heldUnconfirmedShrink(priorCount: 4, newCount: 1), "\(reason)")
        }
        XCTAssertEqual(try Data(contentsOf: store.snapshotURL), before)

        let manual = try await shrunk.capture(reason: .manual, gate: openGate)
        XCTAssertEqual(manual.outcome, .writtenKeepingLastGood(priorCount: 4, newCount: 1))
    }
}

final class ShrinkCoordinatorTests: XCTestCase {
    private struct OutcomeCapturer: SnapshotCapturing {
        let outcome: SnapshotSaveOutcome
        func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
            SnapshotCaptureResult(reason: reason, outcome: outcome, layout: MonitorLayout(origins: [:]),
                                  configKey: "k", windowCount: 3)
        }
    }

    func testUnconfirmedShrinkRecordsSkipAndNothingIsLearnedOrObserved() async {
        let diag = RecordingDiagnostics()
        let learned = LearnedLayoutStore()
        let coord = SnapshotCoordinator(capturer: OutcomeCapturer(outcome: .heldUnconfirmedShrink(priorCount: 42, newCount: 1)),
                                        gate: SnapshotGate(), learnedStore: learned,
                                        liveLayout: { MonitorLayout(origins: [:]) }, diagnostics: diag)
        let observed = ObservedFlag()
        await coord.setSaveObserver { observed.set() }
        await coord.runScheduledSnapshot()
        XCTAssertEqual(diag.events.map(\.name), ["snapshot-skipped"])
        XCTAssertEqual(diag.events.first?.fields["reason"], .string("shrink-unconfirmed"))
        XCTAssertEqual(diag.events.first?.fields["priorWindows"], .int(42))
        XCTAssertEqual(diag.events.first?.fields["newWindows"], .int(1))
        XCTAssertFalse(observed.value)
    }

    @MainActor
    func testManualShrinkShowsSavedNWasMInTheMenu() async {
        let coord = SnapshotCoordinator(capturer: OutcomeCapturer(outcome: .writtenKeepingLastGood(priorCount: 42, newCount: 3)),
                                        gate: SnapshotGate(), liveLayout: { MonitorLayout(origins: [:]) },
                                        diagnostics: RecordingDiagnostics())
        let result = await coord.saveManually()
        XCTAssertEqual(result, .savedAfterShrink(windowCount: 3, priorCount: 42))

        let actions = RestoreMenuActions(coordinator: NoRestore(), snapshots: coord)
        let viewModel = MenuBarViewModel(snapshotActions: actions, restoreActions: actions)
        actions.viewModel = viewModel
        await viewModel.saveNow()
        XCTAssertEqual(viewModel.snapshotNotice, "Saved 3 windows (was 42)")
    }
}

private final class ObservedFlag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

private struct NoRestore: RestoreCoordinating {
    func restoreNow() async -> RestoreOutcome { .noSnapshot }
    func fixMonitors() async -> RestoreOutcome { .noSnapshot }
    func hasSnapshot() async -> Bool { true }
}
