import XCTest
@testable import TotalRekall

private actor CapturingFake: SnapshotCapturing {
    private(set) var captures = 0
    func capture(reason: SnapshotReason, gate token: SnapshotGateToken) async throws -> SnapshotCaptureResult {
        captures += 1
        return SnapshotCaptureResult(reason: reason, outcome: .written, layout: MonitorLayout(origins: [:]),
                                     configKey: "k", windowCount: 2)
    }
}

/// Reports a snapshot once any capture has been written.
private actor FakeRestoreCoordinator: RestoreCoordinating {
    private let capturer: CapturingFake
    init(capturer: CapturingFake) { self.capturer = capturer }
    func restoreNow() async -> RestoreOutcome { .noSnapshot }
    func fixMonitors() async -> RestoreOutcome { .noSnapshot }
    func hasSnapshot() async -> Bool { await capturer.captures > 0 }
}

/// RestoreMenuActions: manual save shares the gated SnapshotCoordinator path and
/// shows its refusal in the menu; hasSnapshot refreshes after every written snapshot.
@MainActor
final class RestoreMenuActionsTests: XCTestCase {
    private struct Rig {
        let gate: SnapshotGate
        let capturer: CapturingFake
        let snapshots: SnapshotCoordinator
        let actions: RestoreMenuActions
        let viewModel: MenuBarViewModel
    }

    private func makeRig() async -> Rig {
        let gate = SnapshotGate()
        let capturer = CapturingFake()
        let snapshots = SnapshotCoordinator(capturer: capturer, gate: gate, liveLayout: { MonitorLayout(origins: [:]) })
        let actions = RestoreMenuActions(coordinator: FakeRestoreCoordinator(capturer: capturer), snapshots: snapshots)
        let viewModel = MenuBarViewModel(snapshotActions: actions, restoreActions: actions)
        actions.viewModel = viewModel
        await snapshots.setSaveObserver { [weak actions] in await actions?.snapshotSaved() }
        return Rig(gate: gate, capturer: capturer, snapshots: snapshots, actions: actions, viewModel: viewModel)
    }

    func testManualSaveDuringDisplayChangeIsRefusedWithReasonInMenu() async {
        let rig = await makeRig()
        let epoch = rig.gate.closeForDisplayChange()
        await rig.viewModel.saveNow()
        XCTAssertEqual(rig.viewModel.snapshotNotice, SnapshotRefusal.displayChangeInProgress.message)
        let refusedCaptures = await rig.capturer.captures
        XCTAssertEqual(refusedCaptures, 0)
        XCTAssertFalse(rig.viewModel.hasSnapshot)

        rig.gate.reopen(ifEpoch: epoch)
        await rig.viewModel.saveNow()
        XCTAssertNil(rig.viewModel.snapshotNotice, "a successful save clears the notice")
        XCTAssertTrue(rig.viewModel.hasSnapshot)
    }

    func testHasSnapshotRefreshesAfterScheduledSave() async {
        let rig = await makeRig()
        let epoch = rig.gate.closeForDisplayChange()
        await rig.snapshots.runScheduledSnapshot()
        XCTAssertFalse(rig.viewModel.hasSnapshot, "a refused tick writes nothing and refreshes nothing")

        rig.gate.reopen(ifEpoch: epoch)
        await rig.snapshots.runScheduledSnapshot()
        XCTAssertTrue(rig.viewModel.hasSnapshot, "Restore Now enables after the first scheduled snapshot")
    }
}

// MARK: - Shrink notice wording (Bug 65 review advisory 4)

@MainActor
final class SavedAfterShrinkNoticeTests: XCTestCase {
    func testSingularAndPluralWindowCounts() {
        XCTAssertEqual(RestoreMenuActions.savedAfterShrinkNotice(windowCount: 1, priorCount: 42),
                       "Saved 1 window (was 42)")
        XCTAssertEqual(RestoreMenuActions.savedAfterShrinkNotice(windowCount: 3, priorCount: 42),
                       "Saved 3 windows (was 42)")
        XCTAssertEqual(RestoreMenuActions.savedAfterShrinkNotice(windowCount: 0, priorCount: 4),
                       "Saved 0 windows (was 4)")
    }
}
