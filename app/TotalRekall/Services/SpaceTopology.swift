// SpaceTopology.swift
// Desktop key = (panel serial, 1-based ordinal among type-0 user Spaces).
// Pure construction over injected topology so tests can feed fixtures; the live SkyLight
// capture is supplied by a separate provider.

import Foundation

/// One Space as reported by SLS (reduced).
struct SpaceInfo: Equatable, Sendable {
    let id64: UInt64
    /// 0 = user desktop; others (fullscreen, etc.) have no ordinal.
    let type: Int
}

/// One display and its Spaces in SLS order, with its resolved panel serial.
struct DisplaySpaces: Equatable, Sendable {
    let serial: PanelIdentity.Serial
    let spaces: [SpaceInfo]

    var userSpaces: [SpaceInfo] { spaces.filter { $0.type == 0 } }
}

enum SpaceTopology {
    enum KeyResult: Equatable, Sendable {
        case key(DesktopKey)
        /// Space is not a user desktop (e.g. fullscreen app); no ordinal.
        case notUserSpace
        /// Panel serial unreadable: skip, do not guess.
        case serialUnavailable
        case spaceNotFound
    }

    static func key(of id64: UInt64, in displays: [DisplaySpaces]) -> KeyResult {
        for d in displays where d.spaces.contains(where: { $0.id64 == id64 }) {
            guard let idx = d.userSpaces.firstIndex(where: { $0.id64 == id64 }) else { return .notUserSpace }
            switch d.serial {
            case .builtin: return .key(DesktopKey(panelSerial: "builtin", ordinal: idx + 1))
            case .panel(let s): return .key(DesktopKey(panelSerial: s, ordinal: idx + 1))
            case .unavailable: return .serialUnavailable
            }
        }
        return .spaceNotFound
    }

    /// Resolves a key back to a Space id on the current topology.
    static func spaceID(for key: DesktopKey, in displays: [DisplaySpaces]) -> UInt64? {
        for d in displays {
            let serial: String
            switch d.serial {
            case .builtin: serial = "builtin"
            case .panel(let s): serial = s
            case .unavailable: continue
            }
            guard serial == key.panelSerial else { continue }
            let user = d.userSpaces
            guard key.ordinal >= 1, key.ordinal <= user.count else { return nil }
            return user[key.ordinal - 1].id64
        }
        return nil
    }
}
