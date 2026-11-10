// LearnedLayoutStore.swift
// The "learned" monitor layouts, one per desk (see DeskLayouts.swift): the panel-serial -> origin
// map from the most recent successful snapshot taken OUTSIDE the pause at that desk. After a replug,
// SwapDetector compares the live layout against the layout learned for the SAME desk. `learn`
// re-checks the SnapshotGate token under the gate lock, so learning is frozen from the first display
// callback.
//
// A desk the app has not seen before is a new desk: no swap check, no hold, the gate reopens and the
// next snapshot learns it.
//
// ACCEPTED RISK: a layout is learned automatically, so a monitor swap that is already present at
// the FIRST dock of a new desk is learned as correct. Seeding from snapshots.json makes that
// persistent (it survives relaunch) until the desk is re-learned. Swaps at every
// later dock of a known desk are detected against that desk's own layout.
//
// Desk names (named desks) persist in UserDefaults keyed by desk key and are loaded when a desk is
// registered, so a name survives relaunch. A desk is registered when it is first learned, seeded, or
// announced by the new-desk event (`registerIfNeeded`). Forget removes the desk's layout, name and its
// window configurations in snapshots.json (through `snapshotPruner`), otherwise the lazy seed would
// resurrect it at the next launch.
//
// Layouts live in memory, seeded lazily at the first lookup from snapshots.json
// (configurations[key].displays), ignoring configurations with no windows exactly as restore does.

import Foundation
import OSLog

/// Desk names live in UserDefaults, which is documented thread-safe but not annotated Sendable.
struct DeskNameStorage: @unchecked Sendable {
    let defaults: UserDefaults
    static let standard = DeskNameStorage(defaults: .standard)
}

actor LearnedLayoutStore {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "learned-layout")

    private var layouts: [String: MonitorLayout] = [:]
    private var learnedAt: [String: Date] = [:]
    private(set) var desks: [Desk] = []
    private let seedSource: (@Sendable () async throws -> SnapshotFile)?
    private var seeded: Bool
    private let defaults: DeskNameStorage?
    private let snapshotPruner: (@Sendable (String) async throws -> Void)?
    /// Persisted desk names by desk key.
    private var names: [String: String]

    static let namesDefaultsKey = "com.productengineered.TotalRekall.deskNames"

    /// - Parameters:
    ///   - initial: a layout to start with (tests); stored under its own desk.
    ///   - seedSource: loads snapshots.json for the lazy launch seed; nil means nothing to seed.
    ///   - defaults: where desk names persist; nil keeps names in memory only (tests).
    ///   - snapshotPruner: removes a desk's configurations from snapshots.json (Forget Desk).
    init(initial: MonitorLayout = MonitorLayout(origins: [:]),
         seedSource: (@Sendable () async throws -> SnapshotFile)? = nil,
         defaults: DeskNameStorage? = nil,
         snapshotPruner: (@Sendable (String) async throws -> Void)? = nil) {
        self.seedSource = seedSource
        self.defaults = defaults
        self.snapshotPruner = snapshotPruner
        names = defaults?.defaults.dictionary(forKey: Self.namesDefaultsKey) as? [String: String] ?? [:]
        seeded = seedSource == nil
        if let key = DeskKey.make(for: initial) {
            layouts[key] = initial
            let name = names[key] ?? DeskNameRules.defaultName(existing: [])
            desks.append(Desk(key: key, name: name))
        }
    }

    /// How the live set relates to the learned desks, plus the matching desk's own layout.
    func lookup(live: MonitorLayout) async -> DeskLookup {
        await seedIfNeeded()
        return DeskLookup.resolve(live: live, layouts: layouts)
    }

    /// The layout learned for the live set's desk; empty for a new desk or a partial set.
    func layout(forLive live: MonitorLayout) async -> MonitorLayout {
        await lookup(live: live).layout
    }

    /// Learned layout for a desk key, nil when unknown. For tests and diagnostics.
    func layout(forDesk key: String) async -> MonitorLayout? {
        await seedIfNeeded()
        return layouts[key]
    }

    /// Updates the learned layout of the new layout's desk only if the gate is still open at the
    /// token's epoch (checked atomically with the assignment). Empty layouts are never learned.
    /// Returns whether it learned.
    @discardableResult
    func learn(_ newLayout: MonitorLayout, at date: Date = Date(), ifGate token: SnapshotGateToken) async -> Bool {
        guard let key = DeskKey.make(for: newLayout) else { return false }
        await seedIfNeeded()
        return token.commitIfValid {
            layouts[key] = newLayout
            learnedAt[key] = date
            register(key: key)
        }
    }

    /// Escape hatch if the user permanently changes a desk: forget everything learned.
    func reset() {
        layouts = [:]
        learnedAt = [:]
        desks = []
        names = [:]
        persistNames()
    }

    // MARK: Desk names and actions (named desks)

    /// Every desk's name, in registration order.
    var allNames: [String] { desks.map(\.name) }

    func name(forDesk key: String) -> String? {
        desks.first { $0.key == key }?.name
    }

    /// Registers the desk (seeding first so default names account for saved desks) and says whether
    /// this call created it. The new-desk event registers at event time so the name the prompt shows
    /// and the registered name are the same string.
    func registerIfNeeded(_ key: String) async -> (desk: Desk, isNew: Bool) {
        await seedIfNeeded()
        return register(key: key)
    }

    /// Renames by captured desk key. Empty and duplicate names are refused; the name is trimmed and
    /// capped at 40 characters. A desk may keep its own name.
    func rename(deskKey key: String, to raw: String) async -> DeskRenameResult {
        await seedIfNeeded()
        guard let index = desks.firstIndex(where: { $0.key == key }) else { return .unknownDesk }
        let others = desks.indices.filter { $0 != index }.map { desks[$0].name }
        if let problem = DeskNameRules.problem(for: raw, otherNames: others) { return .invalid(problem) }
        let name = DeskNameRules.normalized(raw)
        desks[index].name = name
        names[key] = name
        persistNames()
        return .renamed(name)
    }

    /// Re-learns the desk's layout from the live one. Refused unless the live set is still that desk.
    /// The caller owns the busy/untrusted guard. Returns whether it learned.
    @discardableResult
    func relearn(_ live: MonitorLayout, deskKey key: String, at date: Date = Date()) async -> Bool {
        guard DeskKey.make(for: live) == key else { return false }
        await seedIfNeeded()
        layouts[key] = live
        learnedAt[key] = date
        register(key: key)
        return true
    }

    /// Drops the desk: learned layout, name, and its window configurations in snapshots.json. If the
    /// snapshot file cannot be pruned nothing is removed (a half-forgotten desk would be resurrected
    /// by the next launch's seed). Returns whether the desk was forgotten.
    @discardableResult
    func forget(deskKey key: String) async -> Bool {
        await seedIfNeeded()
        guard desks.contains(where: { $0.key == key }) || layouts[key] != nil else { return false }
        do {
            try await snapshotPruner?(key)
        } catch {
            Self.logger.error("desk kept, snapshots not pruned: \(String(describing: error), privacy: .public)")
            return false
        }
        layouts[key] = nil
        learnedAt[key] = nil
        desks.removeAll { $0.key == key }
        names[key] = nil
        persistNames()
        return true
    }

    private func persistNames() {
        defaults?.defaults.set(names, forKey: Self.namesDefaultsKey)
    }

    // MARK: Seeding

    @discardableResult
    private func register(key: String) -> (desk: Desk, isNew: Bool) {
        if let existing = desks.first(where: { $0.key == key }) { return (existing, false) }
        let name = names[key] ?? DeskNameRules.defaultName(existing: desks.map(\.name))
        let desk = Desk(key: key, name: name)
        desks.append(desk)
        if names[key] == nil {
            names[key] = name
            persistNames()
        }
        return (desk, true)
    }

    private func seedIfNeeded() async {
        guard !seeded, let seedSource else { return }
        do {
            let file = try await seedSource()
            seeded = true
            seed(from: file)
        } catch {
            // Unseeded: every desk looks new until the next lookup retries the load.
            Self.logger.error("learned layouts not seeded: \(String(describing: error), privacy: .public)")
        }
    }

    private func seed(from file: SnapshotFile) {
        // Oldest first so default names are stable; the newest configuration wins when lid-open and
        // lid-closed variants of one desk are both saved.
        let configs = file.configurations.values
            .filter { !$0.windows.isEmpty }
            .sorted { ($0.lastSnapshotDate, $0.fingerprint) < ($1.lastSnapshotDate, $1.fingerprint) }
        for config in configs {
            let layout = MonitorLayout.from(snapshotDisplays: config.displays)
            guard let key = DeskKey.make(for: layout) else { continue }
            if layouts[key] != nil, let existing = learnedAt[key], existing > config.lastSnapshotDate { continue }
            layouts[key] = layout
            learnedAt[key] = config.lastSnapshotDate
            register(key: key)
        }
    }
}

/// Reads a desk's persisted name without the store (for the restore log and diagnostics, which run
/// outside the store's actor). Returns nil for an unnamed desk or no desk; callers fall back to the
/// default name, never to the key.
enum DeskNameLookup {
    static func persistedName(forLive live: MonitorLayout, defaults: UserDefaults = .standard) -> String? {
        guard DeskKey.hasExternalPanel(live), let key = DeskKey.make(for: live) else { return nil }
        let names = defaults.dictionary(forKey: LearnedLayoutStore.namesDefaultsKey) as? [String: String]
        return names?[key]
    }
}
