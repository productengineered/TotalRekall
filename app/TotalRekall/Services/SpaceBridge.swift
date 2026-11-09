// SpaceBridge.swift
// Actor facade over the private SkyLight Space APIs. Proven on real hardware.
// PRIVATE API: every private symbol, class and selector is referenced ONLY in this file and
// AXWindowID.swift. The sole move strategy is "perform": build
// `SLSBridgedMoveWindowsToManagedSpaceOperation` via `initWithWindows:spaceID:` then send
// `performWithWMBridgeDelegate`, confirmed by polling `SLSCopySpacesForWindows`.
// The classic `SLSMoveWindowsToManagedSpace` and `SLSTransaction*` paths are proven no-op/broken
// and are NOT ported. The synchronous bridged variant and `invokeFallback` are never called.
// At init a probe verifies every piece; if anything is missing, capability is `.positionOnly`
// and no private call is ever made for moving windows.

import ApplicationServices
import CoreGraphics
import Foundation
import ObjectiveC
import os

// MARK: - Public types

/// What the app may do with Spaces on this macOS build.
enum SpaceBridgeCapability: Equatable, Sendable {
    case full
    /// Space moves are unavailable; windows may only be repositioned. `reason` names what is missing.
    case positionOnly(reason: String)
}

enum SpaceBridgeError: Error, Equatable, Sendable {
    case positionOnlyMode(reason: String)
    case topologyUnavailable
    case moveNotConfirmed(timeoutMS: Int)
    case submitFailed(String)
}

/// A display and its Spaces as reported by SkyLight, before serial resolution.
struct SLSDisplay: Equatable, Sendable {
    /// SLS "Display Identifier": the display UUID string, or "Main" for the primary display.
    let identifier: String
    let spaces: [SpaceInfo]
    let currentSpaceID: UInt64?
}

// MARK: - Probe seams

/// Answers "does this private piece exist?" Injected so the probe is testable.
protocol SpaceSymbolResolving: Sendable {
    func classExists(_ name: String) -> Bool
    func instanceSelectorExists(className: String, selector: String) -> Bool
    func cSymbolExists(_ name: String) -> Bool
}

/// The private calls the bridge makes. Injected so positionOnly can be proven call-free.
protocol SkyLightAPI: Sendable {
    func copyManagedDisplays() throws -> [SLSDisplay]
    func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64]
    func submitMove(windowIDs: [CGWindowID], toSpaceID: UInt64) throws
}

// MARK: - Probe

enum SpaceBridgeProbe {
    static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    static let moveClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    static let initSelector = "initWithWindows:spaceID:"
    static let performSelector = "performWithWMBridgeDelegate"
    static let connectionSymbols = ["CGSMainConnectionID", "SLSMainConnectionID"]
    /// `_AXUIElementGetWindow` is the AX-to-CGWindowID join (AXWindowID.swift); without it snapshots
    /// and restores cannot be trusted, so its absence also forces positionOnly.
    static let requiredCSymbols = [
        "SLSCopyManagedDisplaySpaces", "SLSCopySpacesForWindows", "objc_msgSend", "_AXUIElementGetWindow"
    ]

    /// Pure given the resolver. Never throws or crashes.
    static func evaluate(using resolver: SpaceSymbolResolving) -> SpaceBridgeCapability {
        var missing: [String] = []
        if !resolver.classExists(moveClassName) {
            missing.append("class \(moveClassName)")
        } else {
            if !resolver.instanceSelectorExists(className: moveClassName, selector: initSelector) {
                missing.append("selector \(initSelector)")
            }
            if !resolver.instanceSelectorExists(className: moveClassName, selector: performSelector) {
                missing.append("selector \(performSelector)")
            }
        }
        if !connectionSymbols.contains(where: { resolver.cSymbolExists($0) }) {
            missing.append("symbol \(connectionSymbols.joined(separator: " | "))")
        }
        for name in requiredCSymbols where !resolver.cSymbolExists(name) {
            missing.append("symbol \(name)")
        }
        return missing.isEmpty ? .full : .positionOnly(reason: "missing: " + missing.joined(separator: ", "))
    }
}

/// PRIVATE API: real runtime lookups.
struct LiveSpaceSymbolResolver: SpaceSymbolResolving {
    func classExists(_ name: String) -> Bool { NSClassFromString(name) != nil }

    func instanceSelectorExists(className: String, selector: String) -> Bool {
        guard let cls = NSClassFromString(className) else { return false }
        return class_getInstanceMethod(cls, NSSelectorFromString(selector)) != nil
    }

    func cSymbolExists(_ name: String) -> Bool {
        if let handle = dlopen(SpaceBridgeProbe.skyLightPath, RTLD_NOLOAD | RTLD_LAZY) ?? dlopen(SpaceBridgeProbe.skyLightPath, RTLD_LAZY),
           dlsym(handle, name) != nil { return true }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil  // RTLD_DEFAULT
    }
}

// MARK: - Live SkyLight calls

/// PRIVATE API: the real SkyLight implementation. Stateless; resolves symbols per call.
struct LiveSkyLightAPI: SkyLightAPI {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopyDisplaysFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MsgSendAllocFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias MsgSendInitFn = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?
    private typealias MsgSendVoidFn = @convention(c) (AnyObject, Selector) -> Void

    /// All-Spaces mask for SLSCopySpacesForWindows (yabai kCGSAllSpacesMask).
    private static let allSpacesSelector: Int32 = 0x7

    func copyManagedDisplays() throws -> [SLSDisplay] {
        let cid = try connectionID()
        let fn: CopyDisplaysFn = try Self.symbol("SLSCopyManagedDisplaySpaces")
        guard let raw = fn(cid) else { throw SpaceBridgeError.topologyUnavailable }
        let displays = raw.takeRetainedValue() as NSArray
        var result: [SLSDisplay] = []
        for case let display as NSDictionary in displays {
            guard let spaces = display["Spaces"] as? NSArray else { continue }
            let identifier = display["Display Identifier"] as? String ?? ""
            let current = ((display["Current Space"] as? NSDictionary)?["id64"] as? NSNumber)?.uint64Value
            var infos: [SpaceInfo] = []
            for case let space as NSDictionary in spaces {
                guard let id64 = space["id64"] as? NSNumber else { continue }
                infos.append(SpaceInfo(id64: id64.uint64Value, type: (space["type"] as? NSNumber)?.intValue ?? -1))
            }
            result.append(SLSDisplay(identifier: identifier, spaces: infos, currentSpaceID: current))
        }
        return result
    }

    func spaces(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] {
        let cid = try connectionID()
        let fn: CopySpacesForWindowsFn = try Self.symbol("SLSCopySpacesForWindows")
        guard let raw = fn(cid, Self.allSpacesSelector, Self.windowArray(windowIDs)) else { return [] }
        let array = raw.takeRetainedValue() as NSArray
        return array.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    func submitMove(windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) throws {
        guard let cls = NSClassFromString(SpaceBridgeProbe.moveClassName) else {
            throw SpaceBridgeError.submitFailed("move class missing")
        }
        let initSel = NSSelectorFromString(SpaceBridgeProbe.initSelector)
        let performSel = NSSelectorFromString(SpaceBridgeProbe.performSelector)
        guard let msg = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {  // RTLD_DEFAULT
            throw SpaceBridgeError.submitFailed("objc_msgSend missing")
        }
        guard let allocated = unsafeBitCast(msg, to: MsgSendAllocFn.self)(cls as AnyObject, NSSelectorFromString("alloc")) else {
            throw SpaceBridgeError.submitFailed("+alloc returned nil")
        }
        // Space ID is passed as a raw uint64 (not boxed); windows as a CFArray of CFNumbers.
        guard let opRef = unsafeBitCast(msg, to: MsgSendInitFn.self)(
            allocated.takeUnretainedValue(), initSel, Self.windowArray(windowIDs), spaceID
        ) else {
            throw SpaceBridgeError.submitFailed("initWithWindows:spaceID: returned nil")
        }
        let op = opRef.takeRetainedValue()
        // Async delegate-based submit. NEVER -invokeFallback or a synchronous bridged variant (traps).
        unsafeBitCast(msg, to: MsgSendVoidFn.self)(op, performSel)
    }

    // MARK: helpers

    private func connectionID() throws -> Int32 {
        let handle = try Self.handle()
        for name in SpaceBridgeProbe.connectionSymbols {
            if let ptr = dlsym(handle, name) {
                let cid = unsafeBitCast(ptr, to: ConnectionFn.self)()
                guard cid > 0 else { throw SpaceBridgeError.submitFailed("invalid connection id \(cid)") }
                return cid
            }
        }
        throw SpaceBridgeError.submitFailed("no connection symbol")
    }

    private static func windowArray(_ ids: [CGWindowID]) -> CFArray {
        ids.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
    }

    private static func handle() throws -> UnsafeMutableRawPointer {
        if let h = dlopen(SpaceBridgeProbe.skyLightPath, RTLD_NOLOAD | RTLD_LAZY) { return h }
        if let h = dlopen(SpaceBridgeProbe.skyLightPath, RTLD_LAZY) { return h }
        throw SpaceBridgeError.submitFailed("SkyLight failed to load")
    }

    private static func symbol<Fn>(_ name: String) throws -> Fn {
        guard let ptr = dlsym(try handle(), name) else { throw SpaceBridgeError.submitFailed("symbol \(name) missing") }
        return unsafeBitCast(ptr, to: Fn.self)
    }
}

// MARK: - Actor

actor SpaceBridge {
    private static let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "spacebridge")
    /// Result of the launch-time probe. Immutable after init.
    nonisolated let capability: SpaceBridgeCapability

    private let api: SkyLightAPI
    private let pollIntervalMS: Int
    private let timeoutMS: Int

    init(
        resolver: SpaceSymbolResolving = LiveSpaceSymbolResolver(),
        api: SkyLightAPI = LiveSkyLightAPI(),
        pollIntervalMS: Int = 50,
        timeoutMS: Int = 1500,
        diagnostics: any DiagnosticsRecording = DiagnosticsLog.shared
    ) {
        self.capability = SpaceBridgeProbe.evaluate(using: resolver)
        diagnostics.record(.spaceBridgeProbe(capability: capability))
        self.api = api
        self.pollIntervalMS = pollIntervalMS
        self.timeoutMS = timeoutMS
    }

    /// Live topology in the shape SpaceTopology consumes. Resolves each SLS display identifier to a
    /// panel serial through `serialForIdentifier` (nil result = `.unavailable`, never guessed).
    func displaySpaces(serialForIdentifier: @Sendable (String) -> PanelIdentity.Serial?) throws -> [DisplaySpaces] {
        try api.copyManagedDisplays().map {
            DisplaySpaces(serial: serialForIdentifier($0.identifier) ?? .unavailable, spaces: $0.spaces)
        }
    }

    /// Space IDs containing the given windows (empty if unknown). Read-only; allowed in any mode.
    func spaceIDs(forWindows windowIDs: [CGWindowID]) throws -> [UInt64] {
        try api.spaces(forWindows: windowIDs)
    }

    /// The Space currently shown on the display that owns `spaceID` (used by bring-to-current).
    func currentSpaceID(onDisplayContaining spaceID: UInt64) throws -> UInt64? {
        try api.copyManagedDisplays()
            .first { $0.spaces.contains { $0.id64 == spaceID } }?
            .currentSpaceID
    }

    /// Moves windows to a Space and confirms by polling. Makes zero private calls in positionOnly mode.
    func moveWindows(_ windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) async throws {
        if case .positionOnly(let reason) = capability {
            throw SpaceBridgeError.positionOnlyMode(reason: reason)
        }
        guard !windowIDs.isEmpty else { return }
        try api.submitMove(windowIDs: windowIDs, toSpaceID: spaceID)
        var elapsed = 0
        var lastError: Error?
        while true {
            do {
                let spaces = try api.spaces(forWindows: windowIDs)
                lastError = nil
                if !spaces.isEmpty, spaces.allSatisfy({ $0 == spaceID }) { return }
            } catch {
                lastError = error
            }
            if elapsed >= timeoutMS {
                if let lastError {
                    Self.logger.error("move not confirmed after \(self.timeoutMS)ms; last SLS error: \(String(describing: lastError))")
                }
                throw SpaceBridgeError.moveNotConfirmed(timeoutMS: timeoutMS)
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalMS) * 1_000_000)
            elapsed += pollIntervalMS
        }
    }
}

// MARK: - Display identifier resolution

enum SLSDisplayIdentifier {
    /// Maps an SLS display identifier to a CGDirectDisplayID: "Main" is the primary display,
    /// otherwise the string is a display UUID.
    static func displayID(for identifier: String, online: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        for id in online {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let str = CFUUIDCreateString(nil, uuid) as String? else { continue }
            if str.caseInsensitiveCompare(identifier) == .orderedSame { return id }
        }
        return nil
    }
}
