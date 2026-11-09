// DiagnosticsEvent.swift
// Value types for the app's private diagnostics diary. By construction nothing here can carry a
// window title: values are numbers, flags, or identifier-like tokens, and call sites use the
// per-event constructors below instead of passing free text.

import Foundation

enum DiagnosticsCategory: String, Codable, Sendable, CaseIterable {
    case display, gate, snapshot, automation, restore, monitors, permissions
    case spacebridge, lifecycle, export, setup, notifications
}

/// A single event field value. `string` is for enum raw values and identifiers only.
enum DiagnosticsValue: Sendable, Equatable, Codable {
    case int(Int)
    case bool(Bool)
    case double(Double)
    case string(String)

    /// Identifier from a string-backed enum (never free text).
    static func code<E: RawRepresentable>(_ value: E) -> DiagnosticsValue where E.RawValue == String {
        .string(value.rawValue)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        self = .string(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        }
    }
}

struct DiagnosticsEvent: Sendable, Equatable, Codable {
    let category: DiagnosticsCategory
    /// Stable kebab-case name, e.g. `snapshot-saved`.
    let name: String
    let cycleID: UUID?
    let fields: [String: DiagnosticsValue]

    /// Failures log at `.error`; everything else at `.notice`.
    var isFailure: Bool { name.hasSuffix("-failed") }

    init(_ category: DiagnosticsCategory, _ name: String, cycleID: UUID? = nil,
         fields: [String: DiagnosticsValue] = [:]) {
        self.category = category
        self.name = name
        self.cycleID = cycleID
        self.fields = fields
    }
}

// MARK: - Event constructors (the only sanctioned way to build events)

extension DiagnosticsEvent {
    static func appLaunched(version: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.lifecycle, "app-launched", fields: ["version": .string(version)])
    }

    static func appTerminating() -> DiagnosticsEvent {
        DiagnosticsEvent(.lifecycle, "app-terminating")
    }

    static func snapshotSaved(cycleID: UUID?, windowCount: Int, desktopCount: Int) -> DiagnosticsEvent {
        DiagnosticsEvent(.snapshot, "snapshot-saved", cycleID: cycleID,
                         fields: ["windows": .int(windowCount), "desktops": .int(desktopCount)])
    }

    static func snapshotFailed(cycleID: UUID?, reason: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.snapshot, "snapshot-failed", cycleID: cycleID, fields: ["reason": .string(reason)])
    }

    static func gateDecision(cycleID: UUID?, allowed: Bool, reason: String) -> DiagnosticsEvent {
        DiagnosticsEvent(.gate, "gate-decision", cycleID: cycleID,
                         fields: ["allowed": .bool(allowed), "reason": .string(reason)])
    }

    static func displayChanged(screenCount: Int) -> DiagnosticsEvent {
        DiagnosticsEvent(.display, "display-changed", fields: ["screens": .int(screenCount)])
    }

    static func restoreFinished(cycleID: UUID?, restored: Int, skipped: Int, failed: Int) -> DiagnosticsEvent {
        DiagnosticsEvent(.restore, "restore-finished", cycleID: cycleID,
                         fields: ["restored": .int(restored), "skipped": .int(skipped), "failed": .int(failed)])
    }

    static func permissionChanged(granted: Bool) -> DiagnosticsEvent {
        DiagnosticsEvent(.permissions, "permission-changed", fields: ["granted": .bool(granted)])
    }

    static func sleepWake(_ signal: SleepWakeSignal) -> DiagnosticsEvent {
        DiagnosticsEvent(.lifecycle, signal.rawValue)
    }

    static func exportCompleted(fileCount: Int) -> DiagnosticsEvent {
        DiagnosticsEvent(.export, "export-completed", fields: ["files": .int(fileCount)])
    }
}
