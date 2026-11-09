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
            snapshotDateLoader: SnapshotDateLoader()
        )
        actions.viewModel = viewModel
        // After a relaunch the in-memory result is gone: fall back to restore-log.json.
        Task { [weak viewModel] in await viewModel?.refreshLastRestoreDetail() }
        Task { [weak viewModel] in await viewModel?.seedLastSnapshotDate() }
        menuActions = actions
        menuBarViewModel = viewModel

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
            sessionReadiness: sessionReadiness
        )
        automationController = automation
        wakeObserver.setSessionReadyHandler { await automation.sessionMayBeReady() }
        wakeObserver.start()

        viewModel.accessibilityGranted = accessibilityMonitor.isTrusted
        accessibilityMonitor.onChange = { [weak viewModel, weak self] trusted in
            viewModel?.accessibilityGranted = trusted
            // Revocation re-shows setup once; a grant advances an open window.
            self?.setupViewModel().trustDidChange(trusted)
            DiagnosticsLog.shared.record(.accessibilityChanged(trusted: trusted))
            Task { await automation.accessibilityChanged(trusted: trusted) }
        }
        accessibilityMonitor.start()
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

    /// The single setup model and window, created lazily.
    private func setupViewModel() -> SetupViewModel {
        if let setupModel { return setupModel }
        let model = SetupViewModel(status: accessibilityMonitor)
        setupController = SetupWindowController(model: model)
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
        let learnedStore = LearnedLayoutStore()
        let snapshotCoordinator = SnapshotCoordinator(
            capturer: service,
            gate: snapshotGate,
            learnedStore: learnedStore,
            liveLayout: { MonitorLayout.from(displays: LiveDisplayProvider().currentDisplays()) }
        )
        let restore = RestoreCoordinator(
            trust: SystemAccessibilityTrustChecker(),
            displays: displayProvider,
            snapshots: store,
            learnedLayout: { await learnedStore.layoutForSwapCheck },
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
