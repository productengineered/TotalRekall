// SnapshotDateLoader.swift
// Reads only the newest capture time from snapshots.json so the status line can show a saved
// snapshot's age after a relaunch. Window titles are never exposed or logged.

import Foundation

protocol LastSnapshotDateLoading: Sendable {
    /// Newest saved snapshot time across all configurations, or nil when nothing is saved/readable.
    func load() async -> Date?
}

struct SnapshotDateLoader: LastSnapshotDateLoading {
    let store: SnapshotStore

    init(store: SnapshotStore = SnapshotStore()) { self.store = store }

    func load() async -> Date? {
        // SnapshotStore is an actor, so this read runs off the main thread.
        guard let file = try? await store.load() else { return nil }
        return file.configurations.values.map(\.lastSnapshotDate).max()
    }
}

/// Loader used until the real one is injected: nothing is ever saved.
struct StubLastSnapshotDateLoader: LastSnapshotDateLoading {
    func load() async -> Date? { nil }
}
