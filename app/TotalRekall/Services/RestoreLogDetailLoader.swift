// RestoreLogDetailLoader.swift
// Reads restore-log.json off the main thread and turns it into the menu's "Last restore" detail.
// The menu never touches the file: MenuBarViewModel caches what this returns.

import Foundation

/// Result of one read of restore-log.json.
enum LastRestoreLoad: Equatable, Sendable {
    /// No restore log exists yet.
    case none
    case loaded(LastRestoreDetail)
    /// A log exists but could not be decoded.
    case unreadable
}

protocol LastRestoreDetailLoading: Sendable {
    func load() async -> LastRestoreLoad
}

struct RestoreLogDetailLoader: LastRestoreDetailLoading {
    let store: RestoreLogStore

    init(store: RestoreLogStore = RestoreLogStore()) { self.store = store }

    func load() async -> LastRestoreLoad {
        let store = self.store
        return await Task.detached(priority: .utility) {
            guard store.hasLog else { return LastRestoreLoad.none }
            do {
                return .loaded(RestoreDetailFormatter.detail(from: try store.load()))
            } catch {
                return .unreadable
            }
        }.value
    }
}

/// Loader used until the real one is injected: there is never a log.
struct StubLastRestoreDetailLoader: LastRestoreDetailLoading {
    func load() async -> LastRestoreLoad { .none }
}
