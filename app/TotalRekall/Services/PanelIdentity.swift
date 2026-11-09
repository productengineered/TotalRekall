// PanelIdentity.swift
// Per-panel anchor: IORegistry IOMobileFramebufferShim AlphanumericSerialNumber, bridged to CG
// displays by pairing the Nth-lowest external CGDisplayUnitNumber with the Nth-lowest DCPIndex.
// Measured on real hardware. The unit<->DCPIndex pairing is a hypothesis.
// An unreadable serial is modeled explicitly (nil), never guessed: the monitor fix is skipped.

import CoreGraphics
import Foundation

/// A display as seen by CoreGraphics, reduced to what identity pairing needs.
struct DisplayIdentityInput: Equatable, Sendable {
    let displayID: UInt32
    let unitNumber: UInt32
    let isBuiltin: Bool
}

enum PanelIdentity {
    /// Panel serial for one display. `unavailable` means skip the monitor fix for that display.
    enum Serial: Equatable, Sendable {
        case builtin
        case panel(String)
        case unavailable
    }

    struct Pairing: Equatable, Sendable {
        let serialByDisplayID: [UInt32: Serial]
        /// Non-nil when external pairing failed (count mismatch); externals map to `.unavailable`.
        let note: String?
    }

    // MARK: Pure logic

    /// Parses `ioreg -r -c IOMobileFramebufferShim -l -w0` text into serials ordered by DCPIndex.
    static func parseDCPSerials(ioregText: String) -> [String] {
        let serialKey = "\"AlphanumericSerialNumber\"=\""
        var found: [(Int, String)] = []
        for chunk in ioregText.components(separatedBy: "+-o IOMobileFramebufferShim").dropFirst() {
            guard let idxRange = chunk.range(of: #""DCPIndex" = \d+"#, options: .regularExpression),
                  let idx = Int(chunk[idxRange].split(separator: " ").last ?? ""),
                  let serRange = chunk.range(of: serialKey + #"[^"]+""#, options: .regularExpression)
            else { continue }
            found.append((idx, String(chunk[serRange].dropFirst(serialKey.count).dropLast())))
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// The unit<->DCPIndex bridge: Nth-lowest external unit number gets the Nth-lowest DCPIndex serial.
    /// Count mismatch refuses to pair (externals become `.unavailable`).
    static func pair(displays: [DisplayIdentityInput], serialsInDCPOrder serials: [String]) -> Pairing {
        var map: [UInt32: Serial] = [:]
        for d in displays where d.isBuiltin { map[d.displayID] = .builtin }
        let externals = displays.filter { !$0.isBuiltin }.sorted { $0.unitNumber < $1.unitNumber }
        guard externals.count == serials.count else {
            for d in externals { map[d.displayID] = .unavailable }
            return Pairing(
                serialByDisplayID: map,
                note: "cannot pair: \(externals.count) external display(s) vs \(serials.count) panel serial(s)"
            )
        }
        for (d, serial) in zip(externals, serials) { map[d.displayID] = .panel(serial) }
        return Pairing(serialByDisplayID: map, note: nil)
    }

    // MARK: System calls

    /// Reads ioreg output; nil on any failure.
    static func readIORegText() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-r", "-c", "IOMobileFramebufferShim", "-l", "-w0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Live displays from CoreGraphics.
    static func liveDisplays() -> [DisplayIdentityInput] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map {
            DisplayIdentityInput(displayID: $0, unitNumber: CGDisplayUnitNumber($0), isBuiltin: CGDisplayIsBuiltin($0) != 0)
        }
    }

    /// Live pairing of CG displays to panel serials.
    static func livePairing() -> Pairing {
        let serials = readIORegText().map(parseDCPSerials(ioregText:)) ?? []
        return pair(displays: liveDisplays(), serialsInDCPOrder: serials)
    }
}
