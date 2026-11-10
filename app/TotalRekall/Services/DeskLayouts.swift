// DeskLayouts.swift
// Per-desk learned monitor layouts. A "desk" is one set of connected external panels (the built-in
// display is ignored when comparing and keying sets, so lid open and lid closed are the same desk).
// A laptop with no external panel is its own desk, keyed by the built-in display alone.
//
// Pure value logic only: LearnedLayoutStore owns the mutable state.

import Foundation

/// A monitor setup the app has learned. Lightweight on purpose: the named-desks work builds
/// on this record. `name` defaults to "Desk N" and nothing here shows it in the UI yet.
struct Desk: Equatable, Sendable, Codable, Identifiable {
    var id: String { key }
    /// `DeskKey.make` of the desk's panel set.
    let key: String
    var name: String

    static func defaultName(number: Int) -> String {
        "Desk \(number)"
    }
}

enum DeskKey {
    static let builtinSerial = "builtin"

    /// The panel serials that identify a desk: externals only, or the built-in display alone when
    /// nothing else is connected.
    static func panelSet(_ serials: some Sequence<String>) -> Set<String> {
        let all = Set(serials)
        let externals = all.subtracting([builtinSerial])
        return externals.isEmpty ? all : externals
    }

    static func panelSet(of layout: MonitorLayout) -> Set<String> {
        panelSet(layout.origins.keys)
    }

    /// True when at least one external panel is connected (the built-in display alone is not a docked desk).
    static func hasExternalPanel(_ layout: MonitorLayout) -> Bool {
        !layout.origins.keys.filter { $0 != builtinSerial }.isEmpty
    }

    /// Order-independent key for a layout's desk. Empty layouts have no desk.
    static func make(for layout: MonitorLayout) -> String? {
        let set = panelSet(of: layout)
        return set.isEmpty ? nil : SnapshotKey.make(panelSerials: Array(set))
    }
}

/// How the live monitor set relates to the desks learned so far.
enum DeskMatch: Equatable, Sendable {
    /// No learned desk has this panel set: a new desk (first run there). No swap check, no hold.
    case newDesk
    /// A learned desk has exactly this panel set.
    case knownDesk
    /// A strict subset of a learned desk: most likely a monitor still waking. Wait, then hold; never
    /// learn a partial set as a new desk.
    case subsetOfKnownDesk
}

struct DeskLookup: Equatable, Sendable {
    let match: DeskMatch
    /// The matching desk's own learned layout; empty unless `match == .knownDesk`.
    let layout: MonitorLayout

    static let newDesk = DeskLookup(match: .newDesk, layout: MonitorLayout(origins: [:]))

    static func resolve(live: MonitorLayout, layouts: [String: MonitorLayout]) -> DeskLookup {
        let liveSet = DeskKey.panelSet(of: live)
        guard !liveSet.isEmpty else { return .newDesk }
        if let key = DeskKey.make(for: live), let known = layouts[key] {
            return DeskLookup(match: .knownDesk, layout: known)
        }
        for stored in layouts.values {
            let storedSet = DeskKey.panelSet(of: stored)
            if liveSet.isStrictSubset(of: storedSet) {
                return DeskLookup(match: .subsetOfKnownDesk, layout: MonitorLayout(origins: [:]))
            }
        }
        return .newDesk
    }
}

extension MonitorLayout {
    /// Origins recorded for a saved display set; configurations without a readable panel serial are skipped.
    static func from(snapshotDisplays displays: [DisplaySnapshot]) -> MonitorLayout {
        var origins: [String: Origin] = [:]
        for d in displays {
            if let serial = d.panelSerial { origins[serial] = Origin(x: d.originX, y: d.originY) }
        }
        return MonitorLayout(origins: origins)
    }
}
