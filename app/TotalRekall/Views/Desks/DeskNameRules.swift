// DeskNameRules.swift
// Pure naming rules shared by the setup desk step, the Save this desk? window, Rename and the desk
// store: empty and duplicate names are refused (case, accent and surrounding-space insensitive), a
// desk may keep its own name, names are capped at 40 characters, and the default is the lowest free
// "Desk N".

import Foundation

enum DeskNameRules {
    static let maxLength = 40

    enum Problem: Equatable, Sendable { case empty, duplicate }

    static func cleaned(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clamped(_ raw: String) -> String {
        String(raw.prefix(maxLength))
    }

    /// The stored form of a typed name: trimmed, capped at `maxLength`, trimmed again.
    static func normalized(_ raw: String) -> String {
        cleaned(clamped(cleaned(raw)))
    }

    /// `otherNames` is every desk name EXCEPT the one being edited (so a desk may keep its own name).
    static func problem(for raw: String, otherNames: [String]) -> Problem? {
        let name = cleaned(raw)
        if name.isEmpty { return .empty }
        let taken = otherNames.contains {
            cleaned($0).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return taken ? .duplicate : nil
    }

    static func message(for problem: Problem?) -> String? {
        guard let problem else { return nil }
        switch problem {
        case .empty: return "Give this desk a name."
        case .duplicate: return "Another desk already has that name."
        }
    }

    /// "Desk 1", "Desk 2", ... the lowest number not already used (not `count + 1`, which collides
    /// after a rename or a forget).
    static func defaultName(existing: [String]) -> String {
        let used = Set(existing.map { cleaned($0).lowercased() })
        var number = 1
        while used.contains("desk \(number)") { number += 1 }
        return "Desk \(number)"
    }
}
