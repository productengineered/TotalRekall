import XCTest
@testable import TotalRekall

/// Cross-cutting engine tests: the pure engine pieces composed over trimmed real captures
/// (Fixtures/*.json, with window titles replaced by generic strings).
/// Per-piece behaviour is covered by the per-task suites; these prove the pieces compose on real data.
final class CrossCuttingEngineTests: XCTestCase {
    // MARK: - Fixture decoding

    private struct FixtureWindow: Decodable {
        let windowID: UInt32
        let bundleID: String
        let appName: String
        let windowTitle: String
        let panelSerial: String?
        let spaceOrdinal: Int?
        let sticky: Bool
        let axVisible: Bool
        let frame: SnapshotFrame
    }

    private struct FixtureWindows: Decodable { let windows: [FixtureWindow] }

    private struct FixtureSpaces: Decodable {
        struct Display: Decodable {
            struct Space: Decodable {
                let id64: UInt64
                let ordinal: Int
                let type: Int
                let uuid: String
            }
            let panelSerial: String
            let spaces: [Space]
        }
        let displays: [Display]
    }

    private struct FixtureLayout: Decodable {
        struct Point: Decodable { let x: Int; let y: Int }
        struct Panel: Decodable { let serial: String; let x: Int; let y: Int }
        let builtin: Point
        let panels: [Panel]
    }

    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
                                "missing fixture \(name).json")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private let center = "FAKESERIAL0002"
    private let left = "FAKESERIAL0001"

    private func learnedLayout() throws -> MonitorLayout {
        let f = try load("layout-baseline", as: FixtureLayout.self)
        var origins: [String: MonitorLayout.Origin] = ["builtin": .init(x: f.builtin.x, y: f.builtin.y)]
        for p in f.panels { origins[p.serial] = .init(x: p.x, y: p.y) }
        return MonitorLayout(origins: origins)
    }

    private func topology(_ name: String) throws -> [DisplaySpaces] {
        try load(name, as: FixtureSpaces.self).displays.map { d in
            DisplaySpaces(serial: d.panelSerial == "builtin" ? .builtin : .panel(d.panelSerial),
                          spaces: d.spaces.map { SpaceInfo(id64: $0.id64, type: $0.type) })
        }
    }

    private func fixtureWindows() throws -> [FixtureWindow] {
        try load("snapshot-windows", as: FixtureWindows.self).windows
    }

    private func saved(_ w: FixtureWindow) -> WindowSnapshot {
        WindowSnapshot(
            id: UUID(), bundleID: w.bundleID, appName: w.appName, windowID: w.windowID, windowTitle: w.windowTitle,
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: w.panelSerial,
            spaceOrdinal: w.spaceOrdinal, spaceUUID: nil, spaceIndex: 0, frame: w.frame, isFullscreen: false,
            isMinimized: false, zOrder: 0, sticky: w.sticky ? true : nil, axVisible: w.axVisible)
    }

    private func savedWindows() throws -> [WindowSnapshot] { try fixtureWindows().map(saved) }

    /// Live state: each window sitting on the Space its saved desktop key resolves to in `topology`.
    private func liveOnSavedDesktop(
        _ windows: [WindowSnapshot], topology: [DisplaySpaces], frame: ((WindowSnapshot) -> SnapshotFrame)? = nil,
        axVisible: ((WindowSnapshot) -> Bool)? = nil
    ) -> [LiveWindowState] {
        windows.compactMap { w in
            guard let wid = w.windowID else { return nil }
            let spaces = w.desktopKey.flatMap { SpaceTopology.spaceID(for: $0, in: topology) }.map { [$0] } ?? []
            return LiveWindowState(windowID: wid, frame: frame?(w) ?? w.frame,
                                   axVisible: axVisible?(w) ?? (w.axVisible ?? true), spaceIDs: spaces)
        }
    }

    private func planned(_ plan: RestorePlan, _ windowID: UInt32) throws -> PlannedWindow {
        try XCTUnwrap(plan.windows.first { $0.windowID == windowID }, "no plan entry for window \(windowID)")
    }

    private func shifted(_ f: SnapshotFrame) -> SnapshotFrame {
        SnapshotFrame(x: f.x + 120, y: f.y + 80, width: f.width, height: f.height)
    }

    // MARK: - (a) swapped layout

    func testSwappedPanelsAreDetectedAndPlanRestoresLearnedLayout() throws {
        let learned = try learnedLayout()
        XCTAssertEqual(learned.origins[left], .init(x: -2560, y: 0))
        XCTAssertEqual(learned.origins[center], .init(x: 0, y: 0))

        var swapped = learned
        swapped.origins[left] = learned.origins[center]
        swapped.origins[center] = learned.origins[left]

        XCTAssertEqual(SwapDetector.detect(learned: learned, live: learned), .correct)
        guard case .swapped(let fix) = SwapDetector.detect(learned: learned, live: swapped) else {
            return XCTFail("expected swapped verdict")
        }
        XCTAssertEqual(fix.targets, learned.origins, "plan must re-apply the whole learned layout")
        XCTAssertEqual(fix.targets[left], .init(x: -2560, y: 0))
        XCTAssertEqual(fix.targets[center], .init(x: 0, y: 0))
    }

    // MARK: - (b) clean replug

    func testCleanReplugKeepsSameDesktopsDespiteNewSpaceIDsAndUUIDs() throws {
        let before = try topology("spaces-before-replug")
        let after = try topology("spaces-after-replug")
        let beforeRaw = try load("spaces-before-replug", as: FixtureSpaces.self)
        let afterRaw = try load("spaces-after-replug", as: FixtureSpaces.self)

        // The left panel's Space id64 and UUID changed across the replug (fixture sanity).
        let leftBefore = try XCTUnwrap(beforeRaw.displays.first { $0.panelSerial == left }?.spaces.first)
        let leftAfter = try XCTUnwrap(afterRaw.displays.first { $0.panelSerial == left }?.spaces.first)
        XCTAssertNotEqual(leftBefore.id64, leftAfter.id64)
        XCTAssertNotEqual(leftBefore.uuid, leftAfter.uuid)

        // (serial, ordinal) keys resolve the same desktop on the new topology.
        for display in beforeRaw.displays {
            for space in display.spaces where space.type == 0 {
                let key = DesktopKey(panelSerial: display.panelSerial, ordinal: space.ordinal)
                XCTAssertEqual(SpaceTopology.key(of: space.id64, in: before), .key(key))
                let resolved = try XCTUnwrap(SpaceTopology.spaceID(for: key, in: after))
                let expected = try XCTUnwrap(afterRaw.displays.first { $0.panelSerial == display.panelSerial }?
                    .spaces.first { $0.ordinal == space.ordinal }?.id64)
                XCTAssertEqual(resolved, expected)
            }
        }
        XCTAssertEqual(SpaceTopology.key(of: leftBefore.id64, in: after), .spaceNotFound)
        XCTAssertEqual(SpaceTopology.key(of: leftAfter.id64, in: after),
                       .key(DesktopKey(panelSerial: left, ordinal: 1)))

        // Planning the pre-replug snapshot against the post-replug topology needs no work when the
        // windows sit on the resolved desktops, and never reports a missing desktop.
        let windows = try savedWindows().filter { $0.desktopKey != nil && $0.sticky != true }
        let plan = RestorePlan.build(snapshot: windows, live: liveOnSavedDesktop(windows, topology: after),
                                     topology: after, capability: .full)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(plan.windows.allSatisfy { $0.action == .alreadyCorrect }, "\(plan.windows.map(\.action))")
        XCTAssertFalse(plan.hasWork)

        // Windows still parked on the vanished pre-replug id are moved to the re-resolved id.
        let leftWindow = try XCTUnwrap(windows.first { $0.panelSerial == left })
        let stale = LiveWindowState(windowID: try XCTUnwrap(leftWindow.windowID), frame: leftWindow.frame,
                                    axVisible: true, spaceIDs: [leftBefore.id64])
        let moved = RestorePlan.build(snapshot: [leftWindow], live: [stale], topology: after, capability: .full)
        XCTAssertEqual(moved.windows[0].action,
                       .moveSpace(spaceID: leftAfter.id64, desktop: DesktopKey(panelSerial: left, ordinal: 1), frame: nil))
    }

    // MARK: - (c) hidden-desktop windows

    func testHiddenDesktopWindowsOnCenterPanelBringToCurrent() throws {
        let after = try topology("spaces-after-replug")
        let hidden = try savedWindows().filter { $0.panelSerial == center && ($0.spaceOrdinal ?? 0) >= 2 }
        XCTAssertEqual(Set(hidden.compactMap(\.spaceOrdinal)), [2, 3, 4], "fixture must cover desktops #2-#4")
        XCTAssertTrue(hidden.allSatisfy { $0.axVisible == false })

        let live = liveOnSavedDesktop(hidden, topology: after, frame: { self.shifted($0.frame) })
        let plan = RestorePlan.build(snapshot: hidden, live: live, topology: after, capability: .full)

        for w in hidden {
            let key = try XCTUnwrap(w.desktopKey)
            let spaceID = try XCTUnwrap(SpaceTopology.spaceID(for: key, in: after))
            XCTAssertEqual(try planned(plan, try XCTUnwrap(w.windowID)).action,
                           .bringToCurrent(returnSpaceID: spaceID, frame: w.frame))
        }
        XCTAssertTrue(plan.hasWork)
        XCTAssertTrue(plan.spaceMoveGroups.isEmpty, "bring-to-current is not a grouped Space move")
    }

    // MARK: - (d) desktop missing

    func testWindowOnVanishedDesktopIsSkippedDesktopMissing() throws {
        let full = try topology("spaces-after-replug")
        // Live center panel has only its first desktop; snapshot ordinal 4 no longer exists.
        let live = full.map { d -> DisplaySpaces in
            guard d.serial == .panel(center) else { return d }
            return DisplaySpaces(serial: d.serial, spaces: Array(d.userSpaces.prefix(1)))
        }
        let windows = try savedWindows().filter { $0.panelSerial == center }
        let onFour = try XCTUnwrap(windows.first { $0.spaceOrdinal == 4 })
        let onOne = try XCTUnwrap(windows.first { $0.spaceOrdinal == 1 && $0.axVisible == true })

        let plan = RestorePlan.build(
            snapshot: [onFour, onOne],
            live: liveOnSavedDesktop([onFour, onOne], topology: full),
            topology: live, capability: .full)

        XCTAssertEqual(try planned(plan, try XCTUnwrap(onFour.windowID)).action, .skip(.desktopMissing))
        XCTAssertEqual(try planned(plan, try XCTUnwrap(onOne.windowID)).action, .alreadyCorrect)
    }

    // MARK: - (e) position-only capability

    func testPositionOnlyAttemptsZeroSpaceMovesButStillRestoresFrames() async throws {
        let after = try topology("spaces-after-replug")
        let windows = try savedWindows()
        let visibleCenter = try XCTUnwrap(windows.first { $0.panelSerial == center && $0.spaceOrdinal == 1 && $0.axVisible == true })
        let visibleLeft = try XCTUnwrap(windows.first { $0.panelSerial == left && $0.axVisible == true })
        let hiddenWrongDesktop = try XCTUnwrap(windows.first { $0.panelSerial == center && $0.spaceOrdinal == 3 })
        let subset = [visibleCenter, visibleLeft, hiddenWrongDesktop]

        // Every window sits on the wrong desktop (center desktop #2) with a wrong frame.
        let wrongSpace = try XCTUnwrap(SpaceTopology.spaceID(for: DesktopKey(panelSerial: center, ordinal: 2), in: after))
        let live = subset.map {
            LiveWindowState(windowID: $0.windowID ?? 0, frame: shifted($0.frame),
                            axVisible: $0.axVisible ?? true, spaceIDs: [wrongSpace])
        }
        let plan = RestorePlan.build(snapshot: subset, live: live, topology: after,
                                     capability: .positionOnly(reason: "fixture: bridge probe failed"))

        XCTAssertTrue(plan.spaceMoveGroups.isEmpty)
        for w in plan.windows {
            if case .moveSpace = w.action { XCTFail("positionOnly plan contains a Space move") }
            if case .bringToCurrent = w.action { XCTFail("positionOnly plan contains bring-to-current") }
        }

        let spaces = CCCountingSpaces()
        let elements: [UInt32: FakeAXElement] = [
            try XCTUnwrap(visibleCenter.windowID): FakeAXElement(start: shifted(visibleCenter.frame)),
            try XCTUnwrap(visibleLeft.windowID): FakeAXElement(start: shifted(visibleLeft.frame))
        ]
        let restorer = WindowRestorer(spaces: spaces, writer: CCAXWriter(elements: elements), sleep: { _ in })
        let results = await restorer.execute(plan)

        let moveCalls = await spaces.moveCalls
        XCTAssertEqual(moveCalls, 0, "position-only mode must never attempt a Space move")
        let status = Dictionary(uniqueKeysWithValues: results.map { ($0.windowID ?? 0, $0.status) })
        XCTAssertEqual(status[visibleCenter.windowID ?? 0], .moved)
        XCTAssertEqual(status[visibleLeft.windowID ?? 0], .moved)
        XCTAssertEqual(status[hiddenWrongDesktop.windowID ?? 0], .axUnreachable)
        XCTAssertEqual(elements[visibleCenter.windowID ?? 0]?.frame, visibleCenter.frame)
        XCTAssertEqual(elements[visibleLeft.windowID ?? 0]?.frame, visibleLeft.frame)
    }

    // MARK: - (f) sticky windows

    func testStickyWindowsAreSkipped() throws {
        let after = try topology("spaces-after-replug")
        let windows = try savedWindows()
        let sticky = try XCTUnwrap(windows.first { $0.sticky == true }, "fixture must include a sticky window")
        let ordinary = try XCTUnwrap(windows.first { $0.panelSerial == center && $0.spaceOrdinal == 1 && $0.axVisible == true })

        // Recorded sticky: skipped even though a live window exists with a wrong frame.
        let stickyLive = LiveWindowState(windowID: try XCTUnwrap(sticky.windowID), frame: shifted(sticky.frame),
                                         axVisible: false, spaceIDs: [6, 9, 8, 7])
        // Not recorded as sticky, but live on several Spaces now: also left alone.
        let multiLive = LiveWindowState(windowID: try XCTUnwrap(ordinary.windowID), frame: shifted(ordinary.frame),
                                        axVisible: true, spaceIDs: [6, 9])

        let plan = RestorePlan.build(snapshot: [sticky, ordinary], live: [stickyLive, multiLive],
                                     topology: after, capability: .full)
        XCTAssertEqual(plan.windows.map(\.action), [.skip(.sticky), .skip(.sticky)])
        XCTAssertFalse(plan.hasWork)
    }

    // MARK: - (g) zero-window capture

    func testZeroWindowCaptureNeverReplacesGoodSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossCuttingEngineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        let key = SnapshotKey.make(panelSerials: ["builtin", left, center])
        let windows = try savedWindows()

        func config(_ windows: [WindowSnapshot], at seconds: TimeInterval) -> DisplayConfigSnapshot {
            DisplayConfigSnapshot(fingerprint: key, displayConfigName: "3 displays", displays: [],
                                  lastSnapshotDate: Date(timeIntervalSince1970: seconds), windows: windows)
        }

        let first = try await store.save(config(windows, at: 1_700_000_000), key: key)
        XCTAssertEqual(first, .written)

        let second = try await store.save(config([], at: 1_700_000_300), key: key)
        XCTAssertEqual(second, .skippedZeroWindows(priorCount: windows.count))

        let stored = try await store.load().configurations[key]
        XCTAssertEqual(stored?.windows.count, windows.count)
        XCTAssertEqual(stored?.lastSnapshotDate, Date(timeIntervalSince1970: 1_700_000_000))
    }
}

// MARK: - Fakes

/// Counts every Space-move attempt; `moveCalls` must stay 0 in position-only mode.
private actor CCCountingSpaces: WindowSpaceMoving {
    private(set) var moveCalls = 0

    func spaceIDs(forWindows windowIDs: [CGWindowID]) async throws -> [UInt64] { [] }

    func moveWindows(_ windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) async throws {
        moveCalls += 1
    }

    func currentSpaceID(onDisplayContaining spaceID: UInt64) async throws -> UInt64? { nil }
}

/// Resolves a preset AX element per window id; windows without one are AX-unreachable.
private final class CCAXWriter: AXFrameWriter, @unchecked Sendable {
    private let elements: [UInt32: FakeAXElement]

    init(elements: [UInt32: FakeAXElement]) { self.elements = elements }

    func acquire(windowID: UInt32) -> AXWindowElement? { elements[windowID] }
}
