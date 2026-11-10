// SwapDetector.swift
// Pure comparison of the live panel-serial -> origin map against the learned layout.
// Unreadable serials yield `.unknown` (never guessed).

import Foundation

/// A planned set of origins to apply, keyed by panel serial ("builtin" for the built-in display).
struct LayoutFixPlan: Equatable, Sendable {
    let targets: [String: MonitorLayout.Origin]
}

enum SwapVerdict: Equatable, Sendable {
    case correct
    case swapped(LayoutFixPlan)
    case unknown(reason: String)
}

enum SwapDetector {
    /// macOS edge-snaps requested origins (measured: requested y 691 landed at 695). Origins within
    /// this many points on each axis count as equal.
    static let defaultTolerance = 8

    /// - Parameters:
    ///   - hasUnreadableSerial: true when any live display's panel serial could not be read.
    static func detect(
        learned: MonitorLayout,
        live: MonitorLayout,
        hasUnreadableSerial: Bool = false,
        tolerance: Int = defaultTolerance
    ) -> SwapVerdict {
        if hasUnreadableSerial { return .unknown(reason: "a panel serial is unavailable") }
        if learned.origins.isEmpty { return .unknown(reason: "no learned layout") }
        if live.origins.isEmpty { return .unknown(reason: "no live displays") }
        // The built-in display is ignored when it is the only difference (lid closed: the internal
        // panel may be absent from the live list). Otherwise the sets must match exactly.
        var learned = learned
        var live = live
        if Set(learned.origins.keys) != Set(live.origins.keys),
           DeskKey.panelSet(of: learned) == DeskKey.panelSet(of: live) {
            let externals = DeskKey.panelSet(of: learned)
            learned.origins = learned.origins.filter { externals.contains($0.key) }
            live.origins = live.origins.filter { externals.contains($0.key) }
        }
        guard Set(learned.origins.keys) == Set(live.origins.keys) else {
            return .unknown(reason: "live panels differ from the learned panels")
        }
        let mismatched = learned.origins.filter { serial, want in
            guard let have = live.origins[serial] else { return true }
            return abs(have.x - want.x) > tolerance || abs(have.y - want.y) > tolerance
        }
        if mismatched.isEmpty { return .correct }
        // Re-apply the whole learned layout in one transaction.
        return .swapped(LayoutFixPlan(targets: learned.origins))
    }
}
