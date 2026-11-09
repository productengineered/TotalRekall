// MonitorFixer.swift
// Applies a LayoutFixPlan in ONE CGBeginDisplayConfiguration / CGConfigureDisplayOrigin /
// CGCompleteDisplayConfiguration(.permanently) transaction, inside a self-change suppression scope.
// Mirrors the layout fix proven on real hardware.

import CoreGraphics
import Foundation

/// Implemented by DisplayMonitor: ignores reconfiguration callbacks we caused ourselves.
protocol SelfChangeSuppressor: Sendable {
    func beginSelfChange()
    func endSelfChange()
}

struct NoopSelfChangeSuppressor: SelfChangeSuppressor {
    func beginSelfChange() {}
    func endSelfChange() {}
}

/// Live layout reading: origins by serial, the CG display for each, and serial health.
struct LiveLayoutReading: Equatable, Sendable {
    let layout: MonitorLayout
    let displayIDBySerial: [String: UInt32]
    let hasUnreadableSerial: Bool
}

protocol LayoutReading: Sendable {
    func readLayout() -> LiveLayoutReading
}

/// The CoreGraphics transaction seam.
protocol DisplayConfigApplying: Sendable {
    /// One atomic transaction. False on any failure (the transaction is cancelled).
    func apply(origins: [UInt32: MonitorLayout.Origin]) -> Bool
}

enum FixOutcome: Equatable, Sendable {
    /// A swap was found, fixed and re-checked.
    case verified
    /// The swap check found the layout already correct; nothing was applied.
    case alreadyInOrder
    case unverified(reason: String)
    case skipped(reason: String)
    case failed(reason: String)
}

extension FixOutcome {
    /// Whether this outcome means the layout may still be wrong (drives attention).
    var setsAttention: Bool {
        switch self {
        case .verified, .alreadyInOrder: false
        case .unverified, .skipped, .failed: true
        }
    }
}

struct MonitorFixer: Sendable {
    let reader: LayoutReading
    let applier: DisplayConfigApplying
    let suppressor: SelfChangeSuppressor
    let tolerance: Int
    let settle: @Sendable () -> Void

    init(reader: LayoutReading = LiveLayoutReader(),
         applier: DisplayConfigApplying = CGDisplayConfigApplier(),
         suppressor: SelfChangeSuppressor = NoopSelfChangeSuppressor(),
         tolerance: Int = SwapDetector.defaultTolerance,
         settle: @escaping @Sendable () -> Void = { Thread.sleep(forTimeInterval: 1.0) }) {
        self.reader = reader
        self.applier = applier
        self.suppressor = suppressor
        self.tolerance = tolerance
        self.settle = settle
    }

    /// Detects against `learned` and fixes if swapped. Re-reads afterwards to verify.
    func fix(learned: MonitorLayout) -> FixOutcome {
        let before = reader.readLayout()
        let verdict = SwapDetector.detect(learned: learned, live: before.layout,
                                          hasUnreadableSerial: before.hasUnreadableSerial, tolerance: tolerance)
        let plan: LayoutFixPlan
        switch verdict {
        case .correct: return .alreadyInOrder
        case .unknown(let reason): return .skipped(reason: reason)
        case .swapped(let p): plan = p
        }
        var byDisplay: [UInt32: MonitorLayout.Origin] = [:]
        for (serial, origin) in plan.targets {
            guard let id = before.displayIDBySerial[serial] else {
                return .skipped(reason: "no display for panel \(serial)")
            }
            byDisplay[id] = origin
        }
        suppressor.beginSelfChange()
        defer { suppressor.endSelfChange() }
        guard applier.apply(origins: byDisplay) else { return .failed(reason: "display configuration failed") }
        settle()
        let after = reader.readLayout()
        let recheck = SwapDetector.detect(learned: learned, live: after.layout,
                                          hasUnreadableSerial: after.hasUnreadableSerial, tolerance: tolerance)
        return recheck == .correct ? .verified : .unverified(reason: "layout still differs after apply")
    }
}

// MARK: - Live implementations

struct LiveLayoutReader: LayoutReading {
    func readLayout() -> LiveLayoutReading {
        let pairing = PanelIdentity.livePairing()
        var origins: [String: MonitorLayout.Origin] = [:]
        var ids: [String: UInt32] = [:]
        var unreadable = pairing.note != nil
        for (id, serial) in pairing.serialByDisplayID {
            let name: String
            switch serial {
            case .builtin: name = "builtin"
            case .panel(let s): name = s
            case .unavailable: unreadable = true; continue
            }
            let b = CGDisplayBounds(id)
            origins[name] = MonitorLayout.Origin(x: Int(b.origin.x), y: Int(b.origin.y))
            ids[name] = id
        }
        return LiveLayoutReading(layout: MonitorLayout(origins: origins), displayIDBySerial: ids,
                                 hasUnreadableSerial: unreadable)
    }
}

struct CGDisplayConfigApplier: DisplayConfigApplying {
    func apply(origins: [UInt32: MonitorLayout.Origin]) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        for (id, o) in origins {
            guard CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y)) == .success else {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
        }
        guard CGCompleteDisplayConfiguration(cfg, .permanently) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return true
    }
}
