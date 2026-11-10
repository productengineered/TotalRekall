import XCTest
@testable import TotalRekall

@MainActor
private final class FakePresenter: DeskNamePresenting {
    private(set) var shown: [DeskNameModel] = []
    private(set) var closeCount = 0
    private(set) var isShown = false

    func show(model: DeskNameModel) {
        shown.append(model)
        isShown = true
    }

    func close() {
        closeCount += 1
        isShown = false
    }
}

@MainActor
private final class FakeDeskActions: DeskActions {
    var summaries: [DeskSummary] = []
    private(set) var renames: [(key: String, name: String)] = []
    private(set) var saves: [String] = []
    private(set) var forgets: [String] = []

    func deskSummaries() async -> [DeskSummary] { summaries }
    func deskNames() async -> [String] { summaries.map(\.name) }
    func renameDesk(_ key: String, to name: String) async -> DeskRenameResult {
        renames.append((key, name))
        return .renamed(name)
    }
    func saveDeskArrangement(_ key: String) async -> DeskArrangementResult {
        saves.append(key)
        return .saved(windowCount: 1)
    }
    func forgetDesk(_ key: String) async -> Bool {
        forgets.append(key)
        return true
    }
}

/// Mutable gating inputs.
@MainActor
private final class Env {
    var setupOpen = false
    var awake = true
    var trusted = true
    var cycleRunning = false
    var liveKey: String? = "deskA"

    var conditions: NewDeskPromptCoordinator.Conditions {
        .init(isSetupOpen: { [unowned self] in setupOpen },
              screensAwakeAndUnlocked: { [unowned self] in awake },
              isAccessibilityTrusted: { [unowned self] in trusted },
              isCycleRunning: { [unowned self] in cycleRunning },
              liveDeskKey: { [unowned self] in liveKey })
    }
}

/// Virtual clock for the retry loop: each `sleep` parks until the test calls `tick()`.
private actor Ticker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleeps = 0
    func sleep() async {
        sleeps += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func tick() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }
}

private struct FixedTrust: AccessibilityTrustChecking {
    let value: Bool
    func isProcessTrusted() -> Bool { value }
}

@MainActor
final class NewDeskPromptCoordinatorTests: XCTestCase {
    private var env: Env!
    private var actions: FakeDeskActions!
    private var prompt: FakePresenter!
    private var rename: FakePresenter!
    private var sut: NewDeskPromptCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        makeFixture()
    }

    private func makeFixture() {
        env = Env()
        actions = FakeDeskActions()
        actions.summaries = [DeskSummary(id: "deskA", name: "Desk 2", isCurrent: true),
                             DeskSummary(id: "other", name: "Studio", isCurrent: false)]
        prompt = FakePresenter()
        rename = FakePresenter()
        // No retry task: gating is exercised through explicit reevaluate() calls.
        sut = NewDeskPromptCoordinator(actions: actions, prompt: prompt, rename: rename,
                                       conditions: env.conditions, maxRetries: 0)
    }

    private let event = NewDeskEvent(key: "deskA", name: "Desk 2")

    /// Lets the coordinator's internal tasks run.
    /// With a condition: polls until it holds or a 5 s deadline passes. Without one: lets queued work
    /// drain for a short fixed window (used only to assert that nothing happens).
    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle(until condition: (() -> Bool)? = nil) async {
        let deadline = ContinuousClock.now + (condition == nil ? .milliseconds(150) : .seconds(5))
        while ContinuousClock.now < deadline {
            if let condition, condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Gating

    func testShowsPromptWhenAllConditionsMet() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        XCTAssertEqual(prompt.shown.count, 1)
        let model = prompt.shown[0]
        XCTAssertEqual(model.mode, .newDesk)
        XCTAssertEqual(model.text, "Desk 2")
        XCTAssertEqual(model.otherNames, ["Studio"], "other names exclude the desk being named")
    }

    func testEachGateConditionBlocksUntilItClears() async {
        let blockers: [(String, (Env) -> Void, (Env) -> Void)] = [
            ("setup open", { $0.setupOpen = true }, { $0.setupOpen = false }),
            ("screens asleep or locked", { $0.awake = false }, { $0.awake = true }),
            ("accessibility untrusted", { $0.trusted = false }, { $0.trusted = true }),
            ("cycle running", { $0.cycleRunning = true }, { $0.cycleRunning = false })
        ]
        for (name, block, clear) in blockers {
            makeFixture()
            block(env)
            sut.deskDiscovered(event)
            await settle()
            XCTAssertTrue(prompt.shown.isEmpty, "\(name) must block the prompt")
            clear(env)
            sut.reevaluate()
            await settle { self.prompt.shown.count == 1 }
            XCTAssertEqual(prompt.shown.count, 1, "\(name) cleared: the prompt shows on re-evaluation")
        }
    }

    func testBoundedRetryShowsAfterTheCycleEnds() async {
        // Retry budget is large so it cannot run out while the test waits; the test waits on the
        // retry's own polling (cycle probes), not on wall-clock time.
        var cycleProbes = 0
        var conditions = env.conditions
        let environment: Env = env
        conditions.isCycleRunning = { cycleProbes += 1; return environment.cycleRunning }
        sut = NewDeskPromptCoordinator(actions: actions, prompt: prompt, rename: rename,
                                       conditions: conditions, retryDelay: .milliseconds(5), maxRetries: 100_000)
        env.cycleRunning = true
        sut.deskDiscovered(event)
        await settle { cycleProbes >= 4 }   // the initial check plus at least three retry polls
        XCTAssertGreaterThanOrEqual(cycleProbes, 4)
        XCTAssertTrue(prompt.shown.isEmpty)
        env.cycleRunning = false
        await settle { self.prompt.shown.count == 1 }
        XCTAssertEqual(prompt.shown.count, 1)
    }

    /// The user's real sequence: the new-desk event arrives during the dock-time cycle, the retry gives up
    /// (here: no retry at all) before the cycle ends, and the gate reopening re-checks the prompt.
    func testPromptShowsWhenTheDockTimeCycleEndsEvenIfTheRetryGaveUp() async {
        env.cycleRunning = true
        sut.deskDiscovered(event)
        await settle()
        XCTAssertTrue(prompt.shown.isEmpty, "the cycle is still running")
        env.cycleRunning = false       // the cycle ends and the gate reopens...
        sut.reevaluate()               // ...which is what AppDelegate's onGateReopened calls
        await settle { self.prompt.shown.count == 1 }
        XCTAssertEqual(prompt.shown.count, 1)
        XCTAssertEqual(prompt.shown.first?.mode, .newDesk)
    }

    /// Wired exactly like AppDelegate (`Conditions.live` over a REAL gate and a REAL AccessibilityMonitor,
    /// production retry 2 s x 15 on a virtual clock). The new-desk event arrives while the gate is closed
    /// (as it does inside the cycle); the gate reopens about 9 s later WITHOUT any explicit re-check.
    func testProductionWiringShowsPromptWithinTheRetryWindowAfterTheGateReopens() async throws {
        let gate = SnapshotGate()
        let ax = AccessibilityMonitor(checker: FixedTrust(value: true))
        let conditions = NewDeskPromptCoordinator.Conditions.live(
            gate: gate, accessibility: ax, isSetupOpen: { false }, sessionLocked: { false },
            liveDeskKey: { "deskA" })
        let ticker = Ticker()
        let sut = NewDeskPromptCoordinator(actions: actions, prompt: prompt, rename: rename, conditions: conditions,
                                           sleep: { _ in await ticker.sleep() })
        let epoch = gate.closeForDisplayChange()
        sut.deskDiscovered(event)
        for step in 1...4 {   // 4 x 2 s: each poll finds the gate still closed
            await waitUntil { await ticker.sleeps == step }
            await ticker.tick()
        }
        await waitUntil { await ticker.sleeps == 5 }   // the 4th poll has run and gone back to sleep
        let parked = await ticker.sleeps
        XCTAssertEqual(parked, 5)
        XCTAssertTrue(prompt.shown.isEmpty)
        XCTAssertTrue(gate.reopen(ifEpoch: epoch))
        await ticker.tick()
        await settle { self.prompt.shown.count == 1 }
        XCTAssertEqual(prompt.shown.count, 1, "production retry must show the prompt once the gate reopened")
    }

    func testDeskNotDiscoveredThisRunIsNeverPrompted() async {
        sut.reevaluate()
        await settle()
        XCTAssertTrue(prompt.shown.isEmpty)
    }

    func testBuiltInOnlyDeskNeverPrompts() async {
        env.liveKey = nil
        sut.deskDiscovered(event)
        await settle()
        XCTAssertTrue(prompt.shown.isEmpty)
    }

    // MARK: Once per desk

    func testPromptIsShownOncePerDesk() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        prompt.shown[0].cancel()
        sut.deskDiscovered(event)
        sut.reevaluate()
        await settle()
        XCTAssertEqual(prompt.shown.count, 1)
        XCTAssertTrue(sut.handled.contains("deskA"))
    }

    func testForgottenDeskIsPromptedAgainWhenItReconnects() async {
        sut.deskDiscovered(event)
        await settle { !self.prompt.shown.isEmpty }
        XCTAssertEqual(prompt.shown.count, 1)
        XCTAssertTrue(sut.handled.contains("deskA"))
        prompt.close()
        sut.deskForgotten("deskA")
        XCTAssertFalse(sut.handled.contains("deskA"))
        sut.deskDiscovered(event)
        sut.reevaluate()
        await settle { self.prompt.shown.count == 2 }
        XCTAssertEqual(prompt.shown.count, 2)
    }

    func testSetupHandledDeskIsNeverPrompted() async {
        sut.markHandled("deskA")
        sut.deskDiscovered(event)
        await settle()
        XCTAssertTrue(prompt.shown.isEmpty)
    }

    func testSecondEventWhileWindowOpenIsIgnoredThenRecheckedLater() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        env.liveKey = "deskB"
        sut.deskDiscovered(NewDeskEvent(key: "deskB", name: "Desk 3"))
        await settle()
        XCTAssertEqual(prompt.shown.count, 1, "no second window while one is open")
        // The first prompt is dismissed; the next re-check prompts the (still unhandled) current desk.
        prompt.shown[0].cancel()
        actions.summaries.append(DeskSummary(id: "deskB", name: "Desk 3", isCurrent: true))
        sut.reevaluate()
        await settle { self.prompt.shown.count == 2 }
        XCTAssertEqual(prompt.shown.count, 2)
        XCTAssertEqual(prompt.shown[1].text, "Desk 3")
    }

    // MARK: Captured key, Save, Not Now

    func testSaveActsOnTheKeyCapturedWhenTheWindowOpened() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        env.liveKey = "deskB"   // the user docks elsewhere while the window is open
        let model = prompt.shown[0]
        model.text = "  Home Office  "
        model.save()
        await settle { self.actions.saves.count == 1 }
        XCTAssertEqual(actions.renames.map(\.key), ["deskA"])
        XCTAssertEqual(actions.renames.map(\.name), ["Home Office"])
        XCTAssertEqual(actions.saves, ["deskA"])
        XCTAssertEqual(prompt.closeCount, 1)
    }

    func testSaveRefreshesTheDesksMenu() async {
        var refreshed = 0
        sut.onDesksChanged = { refreshed += 1 }
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        prompt.shown[0].save()
        await settle { refreshed == 1 }
        XCTAssertEqual(refreshed, 1)
    }

    func testNotNowKeepsTheDefaultNameAndTouchesNothing() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        prompt.shown[0].cancel()   // Not Now, Esc, Cmd-W and the close button all end here
        await settle()
        XCTAssertTrue(actions.renames.isEmpty)
        XCTAssertTrue(actions.saves.isEmpty)
        XCTAssertTrue(actions.forgets.isEmpty)
        XCTAssertEqual(prompt.closeCount, 1)
    }

    func testCloseAfterSaveDoesNotDismissOrSaveTwice() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        let model = prompt.shown[0]
        model.save()
        model.cancel()   // the window's close path after Save: idempotent
        await settle { self.actions.saves.count == 1 }
        XCTAssertEqual(actions.renames.count, 1)
        XCTAssertEqual(actions.saves.count, 1)
    }

    // MARK: Rename

    func testRenameUsesAnIndependentWindowAndTheCapturedKey() async {
        sut.deskDiscovered(event)
        await settle { self.prompt.shown.count == 1 }
        sut.presentRename(for: DeskSummary(id: "other", name: "Studio", isCurrent: false))
        await settle { self.rename.shown.count == 1 }
        XCTAssertEqual(prompt.shown.count, 1, "the prompt model is not replaced")
        let model = rename.shown[0]
        XCTAssertEqual(model.mode, .rename)
        XCTAssertEqual(model.text, "Studio")
        XCTAssertEqual(model.otherNames, ["Desk 2"])
        model.text = "Studio 2"
        model.save()
        await settle { self.actions.renames.count == 1 }
        XCTAssertEqual(actions.renames.first?.key, "other")
        XCTAssertTrue(actions.saves.isEmpty, "Rename never saves an arrangement")
    }

    func testRenameCancelAndUnchangedNameChangeNothing() async {
        sut.presentRename(for: DeskSummary(id: "other", name: "Studio", isCurrent: false))
        await settle { self.rename.shown.count == 1 }
        rename.shown[0].cancel()
        sut.presentRename(for: DeskSummary(id: "other", name: "Studio", isCurrent: false))
        await settle { self.rename.shown.count == 2 }
        rename.shown[1].save()   // unchanged name
        await settle()
        XCTAssertTrue(actions.renames.isEmpty)
    }

    // MARK: REC-6

    #if DEBUG
    func testSimulatedDeskNeverWritesAnythingReal() async {
        let promptWindow = FakePresenter()
        let before = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.lowercased().contains("desk") }
        let coordinator = DeskPreviewLauncher.makeCoordinator(prompt: promptWindow, rename: FakePresenter())
        coordinator.deskDiscovered(NewDeskEvent(key: DeskPreviewLauncher.simulatedKey, name: "Desk 2"))
        await settle { promptWindow.shown.count == 1 }
        XCTAssertEqual(promptWindow.shown.count, 1)
        promptWindow.shown[0].text = "Preview Name"
        promptWindow.shown[0].save()
        await settle()
        let after = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.lowercased().contains("desk") }
        XCTAssertEqual(Set(before), Set(after), "the preview must not touch persisted desk state")
    }

    func testPreviewLauncherIgnoresUnrelatedArguments() {
        XCTAssertFalse(DeskPreviewLauncher.runIfRequested(arguments: ["-TRForceUntrusted"]))
        XCTAssertFalse(DeskPreviewLauncher.runIfRequested(arguments: ["-TRDeskPreview", "bogus"]))
    }
    #endif
}
