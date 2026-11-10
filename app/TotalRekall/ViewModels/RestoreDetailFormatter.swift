// RestoreDetailFormatter.swift
// Pure formatter behind the menu's "Last restore" submenu: restore-log.json -> plain-language rows.
// It reads only appName, bundleID and status from each window result. Window titles are never read.

import Foundation

/// What the "Last restore" submenu shows, already formatted. Built off the main actor and cached.
struct LastRestoreDetail: Equatable, Sendable {
    let restoredAt: Date
    /// Why the restore ran (nil in logs written before triggers were recorded).
    let trigger: CycleTrigger?
    /// Already formatted ("Monitors: fixed" when a swap was fixed, "Monitors: already in order" when
    /// the check found nothing to fix); nil omits the line.
    let monitorLine: String?
    /// Sorted, already formatted, at most `RestoreDetailFormatter.maxAppLines`.
    let appLines: [String]
    /// Apps beyond the cap.
    let overflowCount: Int
    /// "X of Y windows" for the parent line; nil for a monitors-only result.
    let restoredCount: Int?
    let totalCount: Int?
    /// The desk's name from the log (nil for logs written before desks were named); shown as one line.
    var deskName: String?
}

enum RestoreDetailFormatter {
    static let maxAppLines = 15

    // MARK: Whole log

    static func detail(from log: RestoreLog) -> LastRestoreDetail {
        let lines = appLines(from: log.windows)
        return LastRestoreDetail(
            restoredAt: log.restoredAt,
            trigger: log.trigger,
            monitorLine: monitorLine(from: log.monitorFix),
            appLines: Array(lines.prefix(maxAppLines)),
            overflowCount: max(0, lines.count - maxAppLines),
            restoredCount: log.counts.restored,
            totalCount: log.counts.total,
            deskName: log.deskName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// A Fix Monitors result has no window list: the in-memory outcome stands in for the log.
    static func detail(monitorFix: FixOutcome, date: Date) -> LastRestoreDetail {
        LastRestoreDetail(restoredAt: date, trigger: nil,
                          monitorLine: monitorLine(from: String(describing: monitorFix)), appLines: [], overflowCount: 0, restoredCount: nil, totalCount: nil)
    }

    // MARK: Monitor line

    /// `FixOutcome` is stored as `String(describing:)`; match by prefix. Reasons are never shown.
    static func monitorLine(from logValue: String?) -> String? {
        guard let value = logValue else { return nil }
        if value.hasPrefix("verified") { return "Monitors: fixed" }
        if value.hasPrefix("alreadyInOrder") { return "Monitors: already in order" }
        if value.hasPrefix("skipped") { return "Monitors: already in order" }
        if value.hasPrefix("unverified") { return "Monitors: fix not verified" }
        if value.hasPrefix("failed") { return "Monitors: couldn't fix" }
        return nil
    }

    // MARK: Trigger line

    static func triggerLine(trigger: CycleTrigger?, date: Date, now: Date,
                            calendar: Calendar = .current, locale: Locale = .current) -> String {
        let stamp = timestamp(date, now: now, calendar: calendar, locale: locale)
        let lead: String
        switch trigger {
        case .displayChange: lead = "After a display change"
        case .wake: lead = "Restored after wake"
        case .launch: lead = "At launch"
        case .manual: lead = "You chose Restore Now"
        case nil: lead = "Restored"
        }
        return "\(lead) · \(stamp)"
    }

    /// Time of day for today; "Yesterday at <time>" for the calendar day before `now`; date and time
    /// otherwise. "Yesterday" is computed from the injected `now` and calendar, never the real clock.
    static func timestamp(_ date: Date, now: Date, calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                         calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(timeStyle) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            let time = date.formatted(timeStyle)
            return String(localized: "Yesterday at \(time)")
        }
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
                                         calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(dateStyle)
    }

    // MARK: App lines

    /// One part of an app's line, in the fixed display order.
    private enum Bucket: Int, CaseIterable {
        case restored, unverified, failed, desktopMissing, unreachable, notFound, panelAbsent
        case helper, minimized, fullScreen, sticky

        init(_ status: RestoreStatus) {
            switch status {
            case .moved, .spaceMoved, .alreadyCorrect: self = .restored
            case .movedUnverified: self = .unverified
            case .failed: self = .failed
            case .axUnreachable: self = .unreachable
            case .skipped(let reason):
                switch reason {
                case .desktopMissing: self = .desktopMissing
                case .notFound: self = .notFound
                case .panelNotConnected: self = .panelAbsent
                case .untitledNoAXMatch: self = .helper
                case .minimized: self = .minimized
                case .fullscreen: self = .fullScreen
                case .sticky: self = .sticky
                }
            }
        }

        /// 1 = sets attention, 2 = left in place, 3 = restored, 4 = skipped on purpose.
        var problemRank: Int {
            switch self {
            case .unverified, .failed, .desktopMissing: 1
            case .unreachable, .notFound, .panelAbsent: 2
            case .restored: 3
            case .helper, .minimized, .fullScreen, .sticky: 4
            }
        }

        func text(count: Int) -> String {
            switch self {
            case .restored: "\(count) restored"
            case .unverified: "\(count) couldn't verify position"
            case .failed: "\(count) couldn't move to its desktop"
            case .desktopMissing: "\(count) desktop no longer exists"
            case .unreachable: "\(count) left in place (couldn't reach)"
            case .notFound: "\(count) left in place (window not found)"
            case .panelAbsent: "\(count) left in place (monitor not connected)"
            case .helper: "\(count) skipped (helper window)"
            case .minimized: "\(count) skipped (minimized)"
            case .fullScreen: "\(count) skipped (full screen)"
            case .sticky: "\(count) skipped (on all desktops)"
            }
        }
    }

    /// Windows grouped by app (name, else bundle ID), one line each, problems first.
    static func appLines(from windows: [RestoreWindowResult]) -> [String] {
        var order: [String] = []
        var counts: [String: [Bucket: Int]] = [:]
        for window in windows {
            let name = window.appName.isEmpty ? window.bundleID : window.appName
            if counts[name] == nil { order.append(name) }
            counts[name, default: [:]][Bucket(window.status), default: 0] += 1
        }
        struct Row { let name: String; let rank: Int; let line: String }
        let rows: [Row] = order.map { name in
            let buckets = counts[name] ?? [:]
            let parts = Bucket.allCases.compactMap { bucket in
                buckets[bucket].map { bucket.text(count: $0) }
            }
            let rank = buckets.keys.map(\.problemRank).min() ?? 4
            return Row(name: name, rank: rank, line: "\(name) — \(parts.joined(separator: ", "))")
        }
        return rows.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.map(\.line)
    }
}
