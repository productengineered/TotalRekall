import AppKit
import XCTest
@testable import TotalRekall

private actor DeskTestCapturer: SnapshotCapturing {
    private(set) var calls = 0
    private var layout: MonitorLayout
    init(layout: MonitorLayout) { self.layout = layout }
    func setLayout(_ new: MonitorLayout) { layout = new }
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        calls += 1
        return SnapshotCaptureResult(reason: reason, outcome: .written, layout: layout, configKey: "k", windowCount: 4)
    }
}

private actor NoSnapshotRestorer: AutoRestoring {
    func restoreNow() async -> RestoreOutcome { .noSnapshot }
    func fixMonitors() async -> RestoreOutcome { .noSnapshot }
}

private actor SilentStatus: AutomationStatusReporting {
    func automationDidBegin() {}
    func automationDidFinish(outcome: RestoreOutcome?) {}
}

private struct AlwaysTrusted: AccessibilityTrustChecking {
    func isProcessTrusted() -> Bool { true }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NewDeskEvent] = []
    func add(_ event: NewDeskEvent) { lock.lock(); items.append(event); lock.unlock() }
    var events: [NewDeskEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class ReopenBox: @unchecked Sendable {
    struct Call { let eventsSeen: Int; let gateOpen: Bool }
    private let lock = NSLock()
    private var items: [Call] = []
    func add(eventsSeen: Int, gateOpen: Bool) {
        lock.lock(); items.append(Call(eventsSeen: eventsSeen, gateOpen: gateOpen)); lock.unlock()
    }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MonitorLayout
    init(_ value: MonitorLayout) { self.value = value }
    /// Runs on every read; lets a test simulate a display callback landing mid-operation.
    nonisolated(unsafe) var onGet: (() -> Void)?
    func get() -> MonitorLayout { onGet?(); lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: MonitorLayout) { lock.lock(); value = new; lock.unlock() }
}

private final class TrustBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Named desks, service layer (named desks): names, the new-desk event and the desk actions.
final class DeskStoreTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "DeskStoreTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func defaults() throws -> DeskNameStorage {
        DeskNameStorage(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    private func layout(_ serials: [String]) -> MonitorLayout {
        MonitorLayout(origins: Dictionary(uniqueKeysWithValues: serials.enumerated().map { ($0.element, .init(x: $0.offset * 1000, y: 0)) }))
    }

    private func key(_ serials: [String]) throws -> String {
        try XCTUnwrap(DeskKey.make(for: layout(serials)))
    }

    private func display(_ serial: String, x: Int) -> DisplaySnapshot {
        DisplaySnapshot(vendorID: 1, productID: 1, serialNumber: serial, panelSerial: serial, unitNumber: 0,
                        iokitLocationPath: nil, resolution: SnapshotSize(width: 100, height: 100),
                        scaleFactor: 1, displayName: serial, originX: x, originY: 0, isMain: x == 0, cgDisplayID: nil)
    }

    private func config(_ serials: [String]) -> (String, DisplayConfigSnapshot) {
        let snapshotKey = SnapshotKey.make(panelSerials: serials)
        let window = WindowSnapshot(
            id: UUID(), bundleID: "com.example", appName: "App", windowID: 1, windowTitle: "W",
            windowIndex: 0, displayFingerprint: nil, displayIndex: 0, panelSerial: "builtin", spaceOrdinal: 1,
            spaceUUID: nil, spaceIndex: 0, frame: SnapshotFrame(x: 0, y: 0, width: 10, height: 10),
            isFullscreen: false, isMinimized: false, zOrder: 0)
        return (snapshotKey, DisplayConfigSnapshot(
            fingerprint: snapshotKey, displayConfigName: "t",
            displays: serials.enumerated().map { display($1, x: $0 * 1000) },
            lastSnapshotDate: Date(timeIntervalSince1970: 10), windows: [window]))
    }

    // MARK: Names

    func testDefaultNameIsLowestFreeAfterRenameAndForget() async throws {
        let store = LearnedLayoutStore()
        let keys = try [["A", "B"], ["C", "D"], ["E", "F"]].map { try key($0) }
        for desk in keys { _ = await store.registerIfNeeded(desk) }
        let initial = await store.allNames
        XCTAssertEqual(initial, ["Desk 1", "Desk 2", "Desk 3"])
        _ = await store.rename(deskKey: keys[1], to: "Studio")
        await store.forget(deskKey: keys[0])
        let fresh = await store.registerIfNeeded(try key(["G", "H"]))
        XCTAssertEqual(fresh.desk.name, "Desk 1", "count + 1 would have produced Desk 3 and collided")
        let names = await store.allNames
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testNamesSurviveRelaunch() async throws {
        let desk = try key(["A", "B"])
        let other = try key(["C", "D"])
        let first = LearnedLayoutStore(defaults: try defaults())
        _ = await first.registerIfNeeded(desk)
        _ = await first.registerIfNeeded(other)
        let renamed = await first.rename(deskKey: other, to: "  Home Office ")
        XCTAssertEqual(renamed, .renamed("Home Office"))

        let second = LearnedLayoutStore(defaults: try defaults())
        let a = await second.registerIfNeeded(other)
        let b = await second.registerIfNeeded(desk)
        XCTAssertEqual(a.desk.name, "Home Office")
        XCTAssertEqual(b.desk.name, "Desk 1")
    }

    func testRenameRefusesEmptyAndDuplicateButKeepsOwnName() async throws {
        let store = LearnedLayoutStore()
        let one = try key(["A", "B"])
        let two = try key(["C", "D"])
        _ = await store.registerIfNeeded(one)
        _ = await store.registerIfNeeded(two)
        let empty = await store.rename(deskKey: one, to: "   ")
        let duplicate = await store.rename(deskKey: one, to: " desk 2 ")
        let own = await store.rename(deskKey: one, to: "DESK 1")
        let unknown = await store.rename(deskKey: "nope", to: "X")
        XCTAssertEqual(empty, .invalid(.empty))
        XCTAssertEqual(duplicate, .invalid(.duplicate))
        XCTAssertEqual(own, .renamed("DESK 1"))
        XCTAssertEqual(unknown, .unknownDesk)
        let long = await store.rename(deskKey: two, to: String(repeating: "x", count: 60))
        XCTAssertEqual(long, .renamed(String(repeating: "x", count: 40)))
    }

    // MARK: Forget

    func testForgetRemovesLayoutNameAndSavedConfigurationsSoRelaunchDoesNotResurrect() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("desk-forget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshots = SnapshotStore(directory: dir)
        let (docked, dockedConfig) = config(["A", "B"])
        let (lidOpen, lidOpenConfig) = config(["builtin", "A", "B"])
        let (kept, keptConfig) = config(["C", "D"])
        for (name, value) in [(docked, dockedConfig), (lidOpen, lidOpenConfig), (kept, keptConfig)] {
            _ = try await snapshots.save(value, key: name)
        }

        let store = LearnedLayoutStore(
            seedSource: { try await snapshots.load() }, defaults: try defaults(),
            snapshotPruner: { deskKey in try await snapshots.removeConfigurations(forDesk: deskKey) })
        let desk = try key(["A", "B"])
        let before = await store.layout(forDesk: desk)
        XCTAssertNotNil(before)
        let forgotten = await store.forget(deskKey: desk)
        XCTAssertTrue(forgotten)

        let layoutAfter = await store.layout(forDesk: desk)
        let nameAfter = await store.name(forDesk: desk)
        XCTAssertNil(layoutAfter)
        XCTAssertNil(nameAfter)
        let remaining = try await snapshots.load().configurations.keys.sorted()
        XCTAssertEqual(remaining, [kept], "both the docked and the lid-open configuration of the desk are gone")

        let relaunched = LearnedLayoutStore(seedSource: { try await snapshots.load() }, defaults: try defaults())
        let lookup = await relaunched.lookup(live: layout(["A", "B"]))
        XCTAssertEqual(lookup.match, .newDesk)
        let names = await relaunched.allNames
        XCTAssertEqual(names.count, 1)
    }

    func testForgetKeepsEverythingWhenSnapshotsCannotBePruned() async throws {
        struct Boom: Error {}
        let store = LearnedLayoutStore(snapshotPruner: { _ in throw Boom() })
        let desk = try key(["A", "B"])
        _ = await store.registerIfNeeded(desk)
        let forgotten = await store.forget(deskKey: desk)
        XCTAssertFalse(forgotten)
        let name = await store.name(forDesk: desk)
        XCTAssertEqual(name, "Desk 1")
    }

    // MARK: New-desk event

    private struct Rig {
        let controller: AutomationController
        let coordinator: SnapshotCoordinator
        let store: LearnedLayoutStore
        let gate: SnapshotGate
        let capturer: DeskTestCapturer
        let events: EventBox
        let live: LiveBox
        var reopened: ReopenBox?

        func fire() async {
            let epoch = gate.closeForDisplayChange()
            await controller.receive(DisplayChangeEvent(added: [1], rawEventCount: 1, throughEpoch: epoch))
            await controller.waitUntilIdle()
        }
    }

    private func makeRig(live: [String], learned: [[String]] = [], trust: TrustBox = TrustBox(),
                         onReopen: ((Int) -> Void)? = nil) async throws -> Rig {
        let gate = SnapshotGate()
        let store = LearnedLayoutStore()
        for desk in learned { _ = await store.learn(layout(desk), ifGate: try XCTUnwrap(gate.token())) }
        let liveBox = LiveBox(layout(live))
        let capturer = DeskTestCapturer(layout: layout(live))
        let coordinator = SnapshotCoordinator(capturer: capturer, gate: gate, learnedStore: store,
                                              liveLayout: { liveBox.get() }, isTrusted: { trust.get() })
        let events = EventBox()
        let (stream, _) = AsyncStream.makeStream(of: DisplayChangeEvent.self)
        let reopened = onReopen == nil ? nil : ReopenBox()
        let controller = AutomationController(
            events: stream, gate: gate, pause: coordinator, restorer: NoSnapshotRestorer(), trust: AlwaysTrusted(),
            status: SilentStatus(), liveLayout: { liveBox.get() }, clock: TestClock(immediate: true),
            onNewDesk: { events.add($0) },
            onGateReopened: { reopened?.add(eventsSeen: events.events.count, gateOpen: gate.isOpen) })
        var rig = Rig(controller: controller, coordinator: coordinator, store: store, gate: gate, capturer: capturer,
                      events: events, live: liveBox)
        rig.reopened = reopened
        return rig
    }

    func testUnseenMonitorSetEmitsExactlyOneEventAndRegistersTheDesk() async throws {
        let rig = try await makeRig(live: ["X", "Y"], learned: [["A", "B"]])
        await rig.fire()
        await rig.fire()
        let events = rig.events.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.key, try key(["X", "Y"]))
        XCTAssertEqual(events.first?.name, "Desk 2")
        let registered = await rig.store.name(forDesk: try key(["X", "Y"]))
        XCTAssertEqual(registered, "Desk 2", "registered at event time, same string the prompt would show")
        XCTAssertTrue(rig.gate.isOpen)
    }

    /// The prompt is re-checked when the gate reopens: the callback fires after the event, with the gate
    /// open, once per finished cycle.
    func testGateReopenedCallbackFiresAfterTheNewDeskEventWithTheGateOpen() async throws {
        let rig = try await makeRig(live: ["X", "Y"], learned: [["A", "B"]], onReopen: { _ in })
        XCTAssertNotNil(rig.reopened)
        await rig.fire()
        let calls = try XCTUnwrap(rig.reopened).calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.eventsSeen, 1, "the new-desk event was already delivered")
        XCTAssertEqual(calls.first?.gateOpen, true, "no cycle running when the prompt is re-checked")
    }

    func testPartialKnownSetEmitsNoEvent() async throws {
        let rig = try await makeRig(live: ["A", "B"], learned: [["A", "B", "C"]])
        await rig.fire()
        XCTAssertTrue(rig.events.events.isEmpty)
        let names = await rig.store.allNames
        XCTAssertEqual(names, ["Desk 1"], "a partial set is never registered as a new desk")
    }

    func testBuiltInDisplayAloneEmitsNoEvent() async throws {
        let rig = try await makeRig(live: ["builtin"])
        await rig.fire()
        XCTAssertTrue(rig.events.events.isEmpty)
    }

    /// AC4: the prompt is pure UI. An ignored event leaves the desk "Desk N", the gate open, and the
    /// next snapshot learns the desk under that name.
    func testIgnoredEventLeavesDefaultNameAndGateOpen() async throws {
        let rig = try await makeRig(live: ["X", "Y"])
        await rig.fire()
        XCTAssertEqual(rig.events.events.count, 1, "nobody consumed it")
        XCTAssertTrue(rig.gate.isOpen)
        await rig.coordinator.runScheduledSnapshot()
        let captures = await rig.capturer.calls
        XCTAssertEqual(captures, 1)
        let summaries = await rig.coordinator.deskSummaries()
        XCTAssertEqual(summaries, [DeskSummary(id: try key(["X", "Y"]), name: "Desk 1", isCurrent: true)])
    }

    // MARK: Desk actions

    func testRenameThroughCoordinatorUpdatesStore() async throws {
        let rig = try await makeRig(live: ["X", "Y"])
        await rig.fire()
        let desk = try key(["X", "Y"])
        let result = await rig.coordinator.renameDesk(desk, to: "Studio")
        XCTAssertEqual(result, .renamed("Studio"))
        let names = await rig.coordinator.deskNames()
        XCTAssertEqual(names, ["Studio"])
    }

    func testSaveArrangementRelearnsAndSnapshotsForTheCurrentDesk() async throws {
        let rig = try await makeRig(live: ["X", "Y"])
        await rig.fire()
        let desk = try key(["X", "Y"])
        let moved = MonitorLayout(origins: ["X": .init(x: 0, y: 0), "Y": .init(x: -1920, y: 0)])
        rig.live.set(moved)
        await rig.capturer.setLayout(moved)
        let result = await rig.coordinator.saveDeskArrangement(desk)
        XCTAssertEqual(result, .saved(windowCount: 4))
        let learned = await rig.store.layout(forDesk: desk)
        XCTAssertEqual(learned, moved)
    }

    func testSaveArrangementDoesNothingWhenTheLiveDeskChanged() async throws {
        let rig = try await makeRig(live: ["X", "Y"])
        await rig.fire()
        let captured = try key(["X", "Y"])
        rig.live.set(layout(["P", "Q"]))
        let result = await rig.coordinator.saveDeskArrangement(captured)
        XCTAssertEqual(result, .notCurrentDesk)
        let calls = await rig.capturer.calls
        XCTAssertEqual(calls, 0)
        let learned = await rig.store.layout(forDesk: captured)
        XCTAssertNil(learned)
    }

    func testSaveArrangementRefusedWhenUntrustedOrBusy() async throws {
        let trust = TrustBox()
        let rig = try await makeRig(live: ["X", "Y"], trust: trust)
        await rig.fire()
        let desk = try key(["X", "Y"])
        trust.set(false)
        let untrusted = await rig.coordinator.saveDeskArrangement(desk)
        XCTAssertEqual(untrusted, .refused(SnapshotRefusal.accessibilityMissing.message))
        trust.set(true)
        _ = rig.gate.closeForDisplayChange()
        let busy = await rig.coordinator.saveDeskArrangement(desk)
        XCTAssertEqual(busy, .refused(SnapshotRefusal.displayChangeInProgress.message))
        let calls = await rig.capturer.calls
        XCTAssertEqual(calls, 0)
    }

    func testSaveArrangementResolvesALayoutUnverifiedHold() async throws {
        let rig = try await makeRig(live: ["X", "Y"], learned: [["X", "Y"]])
        _ = rig.gate.closeForDisplayChange()
        rig.gate.relabel(.layoutUnverified)
        let desk = try key(["X", "Y"])
        let result = await rig.coordinator.saveDeskArrangement(desk)
        XCTAssertEqual(result, .saved(windowCount: 4))
        XCTAssertTrue(rig.gate.isOpen)
    }

    func testRefusedReopenDoesNotRelearnTheLayout() async throws {
        let rig = try await makeRig(live: ["X", "Y"], learned: [["X", "Y"]])
        _ = rig.gate.closeForDisplayChange()
        rig.gate.relabel(.layoutUnverified)
        let desk = try key(["X", "Y"])
        let before = await rig.store.layout(forDesk: desk)
        let moved = MonitorLayout(origins: ["X": .init(x: 0, y: 0), "Y": .init(x: -1920, y: 0)])
        rig.live.set(moved)
        // A raw display callback lands while the live layout is being read.
        rig.live.onGet = { [gate = rig.gate] in
            rig.live.onGet = nil
            _ = gate.closeForDisplayChange()
        }
        let result = await rig.coordinator.saveDeskArrangement(desk)
        guard case .refused = result else { return XCTFail("expected a refusal, got \(result)") }
        XCTAssertFalse(rig.gate.isOpen)
        let after = await rig.store.layout(forDesk: desk)
        XCTAssertEqual(after, before, "a refused reopen must leave the learned layout unchanged")
        let calls = await rig.capturer.calls
        XCTAssertEqual(calls, 0)
    }

    func testForgetThroughCoordinatorDropsTheDesk() async throws {
        let rig = try await makeRig(live: ["X", "Y"])
        await rig.fire()
        await rig.coordinator.runScheduledSnapshot()
        let desk = try key(["X", "Y"])
        let forgotten = await rig.coordinator.forgetDesk(desk)
        XCTAssertTrue(forgotten)
        let summaries = await rig.coordinator.deskSummaries()
        XCTAssertTrue(summaries.isEmpty)
        let lookup = await rig.coordinator.deskLookup(live: layout(["X", "Y"]))
        XCTAssertEqual(lookup.match, .newDesk)
    }
}

@MainActor
private final class FakeDeskActions: DeskActions {
    var summaries: [DeskSummary] = []
    var renameResult: DeskRenameResult = .renamed("Studio")
    var arrangementResult: DeskArrangementResult = .saved(windowCount: 2)
    private(set) var renamed: [String] = []
    private(set) var arrangementsSaved: [String] = []
    private(set) var forgotten: [String] = []

    func deskSummaries() async -> [DeskSummary] { summaries }
    func deskNames() async -> [String] { summaries.map(\.name) }
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult {
        renamed.append(name)
        return renameResult
    }
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult {
        arrangementsSaved.append(key)
        return arrangementResult
    }
    func forgetDesk(_ key: String) async -> Bool {
        forgotten.append(key)
        return true
    }
}

/// Desk actions on the menu view model (no NSMenu items yet; a later change adds those).
@MainActor
final class MenuBarViewModelDeskTests: XCTestCase {
    private func make(current: Bool) async -> (MenuBarViewModel, FakeDeskActions) {
        let actions = FakeDeskActions()
        actions.summaries = [DeskSummary(id: "k", name: "Desk 1", isCurrent: current)]
        let model = MenuBarViewModel(deskActions: actions)
        await model.refreshDesks()
        return (model, actions)
    }

    func testEnabledRules() async {
        let (none, _) = await make(current: false)
        XCTAssertFalse(none.isRenameDeskEnabled)
        XCTAssertFalse(none.isSaveArrangementEnabled)
        XCTAssertFalse(none.isForgetDeskEnabled)

        let (model, _) = await make(current: true)
        XCTAssertTrue(model.isRenameDeskEnabled && model.isSaveArrangementEnabled && model.isForgetDeskEnabled)
        model.state = .working
        XCTAssertTrue(model.isRenameDeskEnabled, "rename stays available while a restore runs")
        XCTAssertFalse(model.isSaveArrangementEnabled)
        XCTAssertFalse(model.isForgetDeskEnabled)
        model.state = .idle
        model.accessibilityGranted = false
        XCTAssertFalse(model.isSaveArrangementEnabled)
    }

    func testNameDeskRenamesThenSavesTheArrangement() async {
        let (model, actions) = await make(current: true)
        let result = await model.nameDesk("k", as: "Studio")
        XCTAssertEqual(result, .saved(windowCount: 2))
        XCTAssertEqual(actions.renamed, ["Studio"])
        XCTAssertEqual(actions.arrangementsSaved, ["k"])
    }

    func testRefusedRenameSavesNothing() async {
        let (model, actions) = await make(current: true)
        actions.renameResult = .invalid(.duplicate)
        let result = await model.nameDesk("k", as: "Desk 1")
        XCTAssertNil(result)
        XCTAssertTrue(actions.arrangementsSaved.isEmpty)
    }

    func testSaveAndForgetRefusedWhileBusy() async {
        let (model, actions) = await make(current: true)
        model.state = .working
        let saved = await model.saveDeskArrangement("k")
        let forgotten = await model.forgetDesk("k")
        XCTAssertEqual(saved, .refused(SnapshotRefusal.restoring.message))
        XCTAssertFalse(forgotten)
        XCTAssertTrue(actions.arrangementsSaved.isEmpty && actions.forgotten.isEmpty)
    }

    func testOtherNamesExcludeTheDeskBeingNamed() async {
        let (model, _) = await make(current: true)
        XCTAssertEqual(model.deskNames(excluding: "k"), [])
        XCTAssertEqual(model.deskNames(excluding: "other"), ["Desk 1"])
    }
}

// MARK: - Desks submenu model and status line (named desks)

@MainActor
final class DesksMenuModelTests: XCTestCase {
    private func make(_ summaries: [DeskSummary]) async -> (MenuBarViewModel, FakeDeskActions) {
        let actions = FakeDeskActions()
        actions.summaries = summaries
        let model = MenuBarViewModel(deskActions: actions)
        await model.refreshDesks()
        return (model, actions)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    private func submenu(_ model: MenuBarViewModel) -> NSMenu {
        let target = NSObject()
        let items = DesksMenuBuilder.items(state: model.desksMenuState, target: target,
                                           rename: #selector(NSObject.description),
                                           saveArrangement: #selector(NSObject.description),
                                           forget: #selector(NSObject.description))
        return items[0].submenu ?? NSMenu()
    }

    func testListsDesksDisabledWithCheckOnTheCurrentOne() async {
        let (model, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true),
                                     DeskSummary(id: "b", name: "Desk 2", isCurrent: false)])
        let menu = submenu(model)
        XCTAssertEqual(titles(menu), ["Studio", "Desk 2", "-", "Rename…", "Save Current Arrangement", "Forget Desk…"])
        XCTAssertEqual(menu.items.prefix(2).map(\.state), [.on, .off])
        XCTAssertEqual(menu.items.prefix(2).map(\.isEnabled), [false, false])
        XCTAssertEqual(menu.items.suffix(3).map(\.isEnabled), [true, true, true])
    }

    func testEmptyListShowsNoDesksYetAndDisablesActions() async {
        let (model, _) = await make([])
        let menu = submenu(model)
        XCTAssertEqual(menu.items.first?.title, "No desks yet")
        XCTAssertEqual(menu.items.first?.isEnabled, false)
        XCTAssertEqual(menu.items.suffix(3).map(\.isEnabled), [false, false, false])
    }

    func testNoCurrentDeskDisablesTheThreeActionsAndChecksNothing() async {
        let (model, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: false)])
        let menu = submenu(model)
        XCTAssertEqual(menu.items.first?.state, .off)
        XCTAssertEqual(menu.items.suffix(3).map(\.isEnabled), [false, false, false])
    }

    func testBusyKeepsRenameButDisablesSaveAndForget() async {
        let (model, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        model.state = .working
        XCTAssertEqual(submenu(model).items.suffix(3).map(\.isEnabled), [true, false, false])
    }

    func testUntrustedDisablesSaveArrangementOnly() async {
        let (model, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        model.accessibilityGranted = false
        XCTAssertEqual(submenu(model).items.suffix(3).map(\.isEnabled), [true, false, true])
    }

    func testAXIdentifiersAreSet() async {
        let (model, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        let ids = submenu(model).items.map { $0.accessibilityIdentifier() }
        XCTAssertEqual(ids.first, "\(AXID.Menu.desksItem).0")
        XCTAssertEqual(Array(ids.suffix(3)), [AXID.Menu.desksRename, AXID.Menu.desksSaveArrangement,
                                              AXID.Menu.desksForget])
    }

    func testSaveCurrentArrangementSetsAOneShotNoticeThatClearsOnClose() async {
        let (model, actions) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        await model.saveCurrentArrangement()
        XCTAssertEqual(actions.arrangementsSaved, ["a"])
        XCTAssertEqual(model.desksMenuState.notice, "Saved this arrangement for Studio")
        model.markDesksNoticeShown()
        model.clearShownNotices()
        XCTAssertNil(model.desksMenuState.notice)
    }

    func testStatusLineUsesTheCurrentDeskNameAndFallsBack() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let locale = Locale(identifier: "en_US")
        let (named, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        XCTAssertEqual(named.statusText(now: now, locale: locale), "Watching Studio · no snapshot yet")
        named.lastSnapshotDate = now.addingTimeInterval(-300)
        XCTAssertTrue(named.statusText(now: now, locale: locale).hasPrefix("Watching Studio · last snapshot"))
        let (none, _) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: false)])
        XCTAssertEqual(none.statusText(now: now, locale: locale), "Watching your desk · no snapshot yet")
        named.autoRestoreEnabled = false
        XCTAssertEqual(named.statusText(now: now, locale: locale), "Auto-restore is off")
    }

    func testForgetDeskForwardsToTheEngine() async {
        let (model, actions) = await make([DeskSummary(id: "a", name: "Studio", isCurrent: true)])
        let forgotten = await model.forgetDesk("a")
        XCTAssertTrue(forgotten)
        XCTAssertEqual(actions.forgotten, ["a"])
    }
}
