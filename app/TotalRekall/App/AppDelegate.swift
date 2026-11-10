import AppKit
import os
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock = InstanceLock()
    private let accessibilityMonitor: AccessibilityMonitor
    private let launchAtLoginService = LaunchAtLoginService()
    /// Single source of truth for the snapshot pause: DisplayMonitor closes it, AutomationController
    /// reopens it, every snapshot and learned-layout write re-checks it.
    private let snapshotGate: SnapshotGate
    private let displayMonitor: DisplayMonitor
    private var menuActions: RestoreMenuActions?
    private var menuBarViewModel: MenuBarViewModel?
    private var statusItemController: StatusItemController?
    private var automationController: AutomationController?
    /// Sets the screens-asleep snapshot hold and clears it once windows can be read again.
    private let wakeObserver: SystemWakeObserver
    /// Shared AX-join readiness check (snapshot hold + wake-cycle hold).
    private let sessionReadiness: LiveSessionReadinessProbe
    /// Strong reference: UNUserNotificationCenter holds its delegate weakly.
    private var notificationHandler: NotificationResponseHandler?
    /// Created on first use; there is only ever one setup window.
    private var setupModel: SetupViewModel?
    private var setupController: SetupWindowController?
    /// The engine side of named desks; the setup step's provider is built on it.
    private var deskManager: DeskManaging?
    /// Decides when "Save this desk?" appears and owns the Rename window.
    private var deskPrompt: NewDeskPromptCoordinator?

    override init() {
        #if DEBUG
        // -TRForceUntrusted exercises the Accessibility-missing path without revoking the real TCC grant.
        if ProcessInfo.processInfo.arguments.contains("-TRForceUntrusted") {
            accessibilityMonitor = AccessibilityMonitor(checker: ForcedUntrustedChecker())
        } else {
            accessibilityMonitor = AccessibilityMonitor()
        }
        #else
        accessibilityMonitor = AccessibilityMonitor()
        #endif
        let gate = SnapshotGate()
        snapshotGate = gate
        displayMonitor = DisplayMonitor(snapshotGate: gate)
        let readiness = LiveSessionReadinessProbe()
        sessionReadiness = readiness
        wakeObserver = SystemWakeObserver(gate: gate, readiness: readiness)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests must never touch real displays, windows, or the status bar.
        guard !Self.isRunningAsXCTestHost else { return }
        // Single-instance guard runs first: a second copy must exit before starting any service.
        guard instanceLock.tryAcquire() else {
            // Not the writer process: this exit is logged to os.Logger only, never to the shared file.
            Logger(subsystem: DiagnosticsLog.subsystem, category: "lifecycle")
                .notice("second instance exiting at the instance lock")
            NSApp.terminate(nil)
            return
        }
        // Set the notification delegate before anything else runs so a click that launched the app is
        // delivered to it. Setting a delegate does not request authorization.
        let handler = NotificationResponseHandler()
        notificationHandler = handler
        UNUserNotificationCenter.current().delegate = handler
        // Exactly one writer process: the file sink starts only after the XCTest guard and the lock.
        DiagnosticsLog.shared.startFileSink()
        // Accessory (LSUIElement) app: no Dock icon, no window.
        let wiring = makeWiring()
        let info = Bundle.main.infoDictionary
        DiagnosticsLog.shared.record(.appLaunchedDetail(
            version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibilityTrusted: accessibilityMonitor.isTrusted,
            capability: wiring.capability
        ))
        let actions = RestoreMenuActions(coordinator: wiring.restore, snapshots: wiring.snapshotCoordinator)
        let viewModel = MenuBarViewModel(
            snapshotActions: actions, restoreActions: actions, logProvider: RestoreLogFileProvider(),
            exporter: wiring.exporter, revealer: WorkspaceFileRevealer(),
            detailLoader: RestoreLogDetailLoader(),
            snapshotDateLoader: SnapshotDateLoader(),
            deskActions: DeskMenuActions(manager: wiring.snapshotCoordinator)
        )
        actions.viewModel = viewModel
        // After a relaunch the in-memory result is gone: fall back to restore-log.json.
        Task { [weak viewModel] in await viewModel?.refreshLastRestoreDetail() }
        Task { [weak viewModel] in await viewModel?.seedLastSnapshotDate() }
        Task { [weak viewModel] in await viewModel?.refreshDesks() }
        menuActions = actions
        menuBarViewModel = viewModel
        deskManager = wiring.snapshotCoordinator
        let deskPrompt = makeDeskPrompt(actions: DeskMenuActions(manager: wiring.snapshotCoordinator),
                                        viewModel: viewModel, snapshots: wiring.snapshotCoordinator)
        self.deskPrompt = deskPrompt

        launchAtLoginService.selfHeal()
        statusItemController = StatusItemController(
            viewModel: viewModel, launchAtLogin: LaunchAtLoginMenuAdapter(service: launchAtLoginService)
        )
        // Every written snapshot (launch, scheduled, manual) refreshes Restore Now availability.
        Task { [snapshotCoordinator = wiring.snapshotCoordinator, weak actions] in
            await snapshotCoordinator.setSaveObserver { [weak actions] in await actions?.snapshotSaved() }
            await actions?.refreshHasSnapshot()
        }

        let automation = AutomationController(
            events: displayMonitor.events,
            gate: snapshotGate,
            pause: wiring.snapshotCoordinator,
            restorer: wiring.restore,
            trust: SystemAccessibilityTrustChecker(),
            status: NotifyingAutomationStatus(inner: MenuAutomationStatus(viewModel: viewModel),
                                              notifier: ProblemNotifier()),
            liveLayout: { MonitorLayout.from(displays: LiveDisplayProvider().currentDisplays()) },
            wake: wakeObserver,
            sessionReadiness: sessionReadiness,
            // Fire-and-forget: hop to the main actor; a prompt that is never shown holds nothing.
            onNewDesk: { [weak deskPrompt] event in
                Task { @MainActor in deskPrompt?.deskDiscovered(event) }
            },
            // The new-desk event fires inside the dock-time cycle, while the gate is still closed (and a
            // follow-up cycle can keep it closed for seconds). When the gate reopens the prompt is
            // re-checked right then, instead of relying on a timer that may already have given up.
            onGateReopened: { [weak deskPrompt] in
                Task { @MainActor in deskPrompt?.reevaluate() }
            }
        )
        automationController = automation
        wakeObserver.setSessionReadyHandler { await automation.sessionMayBeReady() }
        wakeObserver.start()

        viewModel.accessibilityGranted = accessibilityMonitor.isTrusted
        accessibilityMonitor.onChange = { [weak viewModel, weak self] trusted in
            viewModel?.accessibilityGranted = trusted
            // Revocation re-shows setup once; a grant advances an open window.
            self?.setupViewModel().trustDidChange(trusted)
            if trusted { self?.deskPrompt?.reevaluate() }
            DiagnosticsLog.shared.record(.accessibilityChanged(trusted: trusted))
            Task { await automation.accessibilityChanged(trusted: trusted) }
        }
        accessibilityMonitor.start()
        statusItemController?.onRenameDesk = { [weak self] desk in self?.deskPrompt?.presentRename(for: desk) }
        statusItemController?.onShowSetup = { [weak self] in self?.setupViewModel().presentFromMenu() }
        statusItemController?.onMenuWillOpen = { [weak monitor = accessibilityMonitor, weak viewModel, gate = snapshotGate] in
            monitor?.refresh()
            // In-memory read of the gate's current pause reason; no file I/O.
            viewModel?.pauseReason = gate.acceptsSnapshots ? nil : gate.refusal
        }

        Task { [displayMonitor] in
            await displayMonitor.start()
            await automation.start()
        }
        // Launch decision: untrusted or never-completed shows setup; trusted and done stays hidden.
        var previewingSetup = false
        #if DEBUG
        previewingSetup = SetupPreviewLauncher.runIfRequested()
        // REC-6: raise the Save this desk? / Rename window on fake collaborators (never writes the store).
        if DeskPreviewLauncher.runIfRequested() { previewingSetup = true }
        #endif
        if !previewingSetup { setupViewModel().evaluateLaunch() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-TRSimulateProblemNotification") {
            // A sample 22 of 24 partial through the real reporter path (menu attention + notification).
            Task {
                try? await Task.sleep(for: .seconds(2))
                await automation.simulateFinishedCycle(outcome: .restored(Self.sampleProblemSummary()))
            }
        }
        #endif
    }

    /// Builds the prompt coordinator with the live gating conditions.
    private func makeDeskPrompt(actions: DeskActions, viewModel: MenuBarViewModel,
                                snapshots: SnapshotCoordinator) -> NewDeskPromptCoordinator {
        let gate = snapshotGate
        let monitor = accessibilityMonitor
        let conditions = NewDeskPromptCoordinator.Conditions.live(
            gate: gate, accessibility: monitor,
            isSetupOpen: { [weak self] in self?.setupController?.isShown == true },
            liveDeskKey: {
                let live = MonitorLayout.from(displays: LiveDisplayProvider().currentDisplays())
                return DeskKey.hasExternalPanel(live) ? DeskKey.make(for: live) : nil
            })
        let coordinator = NewDeskPromptCoordinator(
            actions: actions, prompt: DeskNameWindowController(), rename: DeskNameWindowController(),
            conditions: conditions, diagnostics: DiagnosticsLog.shared)
        coordinator.onDesksChanged = { [weak viewModel] in await viewModel?.refreshDesks() }
        // Forget Desk: a forgotten desk reconnected in the same run is prompted again.
        viewModel.onDeskForgotten = { [weak coordinator] key in coordinator?.deskForgotten(key) }
        announceForgottenDesks(from: snapshots, to: coordinator)
        return coordinator
    }

    /// A forgotten desk that is still connected when the next snapshot is written gets the Save this desk? prompt.
    private func announceForgottenDesks(from coordinator: SnapshotCoordinator, to prompt: NewDeskPromptCoordinator) {
        Task { [weak prompt] in
            await coordinator.setNewDeskHandler { event in
                Task { @MainActor in prompt?.deskDiscovered(event) }
            }
        }
    }

    /// The single setup model and window, created lazily.
    private func setupViewModel() -> SetupViewModel {
        if let setupModel { return setupModel }
        let model = SetupViewModel(status: accessibilityMonitor)
        if let deskManager {
            let service = SetupDeskService(
                manager: deskManager,
                liveLayout: { MonitorLayout.from(displays: LiveDisplayProvider().currentDisplays()) })
            // The setup step owns the first desk (D9): a desk it handled is never prompted.
            service.onHandled = { [weak self] key in self?.deskPrompt?.markHandled(key) }
            model.deskProvider = service
        }
        setupController = SetupWindowController(model: model)
        // When setup closes, a desk that was waiting for the prompt gets its turn.
        let controllerClose = model.onClose
        model.onClose = { [weak self] in
            controllerClose?()
            self?.deskPrompt?.reevaluate()
        }
        setupModel = model
        return model
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningAsXCTestHost else { return }
        accessibilityMonitor.stop()
        DiagnosticsLog.shared.record(.appTerminating())
        // Bounded wait (<= 0.5 s) so the final events reach the file before the process exits.
        Thread.sleep(forTimeInterval: 0.3)
        instanceLock.release()
    }

    /// True when this process is the XCTest host app. With Accessibility granted, starting the real
    /// services here could reconfigure monitors or move windows during a test run, so launch starts nothing.
    static var isRunningAsXCTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    #if DEBUG
    private struct ForcedUntrustedChecker: AccessibilityTrustChecking {
        func isProcessTrusted() -> Bool { false }
    }

    private static func sampleProblemSummary() -> RestoreSummary {
        let statuses: [RestoreStatus] = Array(repeating: .moved, count: 22) + Array(repeating: .failed, count: 2)
        let results = statuses.enumerated().map { index, status in
            RestoreWindowResult(snapshotID: UUID(), windowID: UInt32(index + 1), bundleID: "com.example.sample",
                                appName: "Sample", title: "", status: status)
        }
        return RestoreSummary(results: results, date: Date())
    }
    #endif

    private func makeExporter(builder: DiagnosticsBundleBuilder) -> DiagnosticsExporter {
        var simulated: SimulatedExportFailure?
        var delay: Duration?
        #if DEBUG
        // Test seams so the exporting and failure states can be observed (REC-4).
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-TRSimulateExportFailure"), flag + 1 < args.count {
            simulated = SimulatedExportFailure(rawValue: args[flag + 1])
        }
        if let flag = args.firstIndex(of: "-TRExportDelay"), flag + 1 < args.count,
           let seconds = Double(args[flag + 1]) {
            delay = .seconds(seconds)
        }
        #endif
        return DiagnosticsExporter(builder: builder, simulatedFailure: simulated, artificialDelay: delay)
    }

    /// Manual dependency wiring with the real services.
    private struct Wiring {
        let restore: RestoreCoordinator
        let snapshotCoordinator: SnapshotCoordinator
        let capability: SpaceBridgeCapability
        let exporter: DiagnosticsExporter
    }

    private func makeWiring() -> Wiring {
        let store = SnapshotStore()
        let bridge = SpaceBridge()
        let displayProvider = LiveDisplayProvider()
        let axProbe = LiveAXWindowProbe()
        let service = SnapshotService(store: store, bridge: bridge)
        let learnedStore = LearnedLayoutStore(
            seedSource: { try await store.load() },
            defaults: .standard,
            snapshotPruner: { deskKey in try await store.removeConfigurations(forDesk: deskKey) }
        )
        let snapshotCoordinator = SnapshotCoordinator(
            capturer: service,
            gate: snapshotGate,
            learnedStore: learnedStore,
            liveLayout: { MonitorLayout.from(displays: LiveDisplayProvider().currentDisplays()) },
            isTrusted: { SystemAccessibilityTrustChecker().isProcessTrusted() }
        )
        let restore = RestoreCoordinator(
            trust: SystemAccessibilityTrustChecker(),
            displays: displayProvider,
            snapshots: store,
            learnedLayout: { live in await learnedStore.layout(forLive: live) },
            fixer: MonitorFixer(suppressor: displayMonitor),
            topology: LiveSpaceTopologyProvider(bridge: bridge, displayProvider: displayProvider),
            liveWindows: LiveWindowStateProvider(bridge: bridge, windowList: LiveWindowListProvider(), axProbe: axProbe),
            restorer: WindowRestorer(spaces: bridge),
            logWriter: RestoreLogStore(),
            capability: bridge.capability
        )
        let topology = LiveSpaceTopologyProvider(bridge: bridge, displayProvider: displayProvider)
        let bundleBuilder = DiagnosticsBundleBuilder.live(
            snapshotStore: store, displayProvider: displayProvider, topology: topology,
            capability: bridge.capability,
            accessibilityTrusted: { SystemAccessibilityTrustChecker().isProcessTrusted() })
        return Wiring(restore: restore, snapshotCoordinator: snapshotCoordinator,
                      capability: bridge.capability, exporter: makeExporter(builder: bundleBuilder))
    }
}
