// AXFrameWriter.swift
// Verified AX frame writes. Proven on real hardware (macOS 27.0):
// size -> position -> size, then a read-back poll every 50 ms up to 600 ms within tolerance. On a miss,
// up to 3 retries in the order position -> size -> position. AXEnhancedUserInterface is switched off
// around the move and restored afterwards. All AX calls sit behind protocols so the logic is testable.

import ApplicationServices
import CoreGraphics
import Foundation

/// One AX window, addressed for frame writes.
protocol AXWindowElement: AnyObject {
    func setSize(_ size: CGSize) -> Bool
    func setPosition(_ point: CGPoint) -> Bool
    func readFrame() -> SnapshotFrame?
    /// Switches the owning app's AXEnhancedUserInterface off. Returns true only if it was on and was turned off.
    func disableEnhancedUI() -> Bool
    func restoreEnhancedUI()
}

/// Resolves AX elements by CGWindowID. Always re-acquire after a Space move; old handles go stale.
protocol AXFrameWriter: Sendable {
    func acquire(windowID: UInt32) -> AXWindowElement?
}

struct FrameWriteTiming: Sendable, Equatable {
    var pollIntervalMS: Int = 50
    var verifyWindowMS: Int = 600
    var reacquireWindowMS: Int = 500
    /// After a Space move the app's AX window list can lag the move, so re-acquire waits longer,
    /// with a bounded backoff: pollIntervalMS, doubling, capped at reacquireBackoffMaxStepMS.
    var reacquireAfterSpaceMoveMS: Int = 1_500
    var reacquireBackoffMaxStepMS: Int = 400
    var tolerance: Double = RestorePlan.defaultFrameTolerance
    var maxRetries: Int = 3

    static let standard = FrameWriteTiming()
}

struct VerifiedFrameWrite: Equatable, Sendable {
    let verified: Bool
    let actual: SnapshotFrame?
    let attempts: Int
    let positionOK: Bool
    let sizeOK: Bool
}

enum VerifiedFrameWriter {
    typealias Sleeper = @Sendable (Int) async -> Void

    /// Applies `target` and verifies it by reading the frame back.
    static func write(
        _ target: SnapshotFrame,
        to element: AXWindowElement,
        timing: FrameWriteTiming = .standard,
        sleep: Sleeper
    ) async -> VerifiedFrameWrite {
        let size = CGSize(width: target.width, height: target.height)
        let point = CGPoint(x: target.x, y: target.y)

        let toggled = element.disableEnhancedUI()
        defer { if toggled { element.restoreEnhancedUI() } }

        // First pass: the leading size set avoids clamping when crossing displays.
        let size1 = element.setSize(size)
        var positionOK = element.setPosition(point)
        let size2 = element.setSize(size)
        var sizeOK = size1 && size2
        var attempts = 1
        var polled = await poll(element, target: target, timing: timing, sleep: sleep)

        // Retries for stubborn windows (Chromium/Electron on negative-x displays): position -> size -> position.
        while !polled.ok && attempts <= timing.maxRetries {
            let p1 = element.setPosition(point)
            let s = element.setSize(size)
            let p2 = element.setPosition(point)
            positionOK = p1 && p2
            sizeOK = s
            attempts += 1
            polled = await poll(element, target: target, timing: timing, sleep: sleep)
        }
        return VerifiedFrameWrite(verified: polled.ok, actual: polled.frame, attempts: attempts,
                                  positionOK: positionOK, sizeOK: sizeOK)
    }

    /// Reads the frame immediately, then every `pollIntervalMS` until `verifyWindowMS` elapses.
    private static func poll(
        _ element: AXWindowElement, target: SnapshotFrame, timing: FrameWriteTiming, sleep: Sleeper
    ) async -> (frame: SnapshotFrame?, ok: Bool) {
        var last: SnapshotFrame?
        let steps = timing.pollIntervalMS > 0 ? timing.verifyWindowMS / timing.pollIntervalMS : 0
        for i in 0...steps {
            if let f = element.readFrame() {
                last = f
                if RestorePlan.framesMatch(f, target, tolerance: timing.tolerance) { return (f, true) }
            }
            if i < steps { await sleep(timing.pollIntervalMS) }
        }
        return (last, false)
    }

    /// The sleeps `reacquireAfterSpaceMove` makes between attempts. Bounded: sums to at least
    /// `reacquireAfterSpaceMoveMS` and never more than one capped step beyond it. Pure.
    static func spaceMoveBackoff(_ timing: FrameWriteTiming) -> [Int] {
        guard timing.pollIntervalMS > 0, timing.reacquireAfterSpaceMoveMS > 0 else { return [] }
        let cap = max(timing.pollIntervalMS, timing.reacquireBackoffMaxStepMS)
        var steps: [Int] = []
        var step = timing.pollIntervalMS
        var total = 0
        while total < timing.reacquireAfterSpaceMoveMS {
            steps.append(step)
            total += step
            step = min(step * 2, cap)
        }
        return steps
    }

    /// Re-acquire after a Space move: tries immediately, then after each backoff step.
    static func reacquireAfterSpaceMove(
        windowID: UInt32, writer: AXFrameWriter, timing: FrameWriteTiming = .standard, sleep: Sleeper
    ) async -> AXWindowElement? {
        if let el = writer.acquire(windowID: windowID) { return el }
        for step in spaceMoveBackoff(timing) {
            await sleep(step)
            if let el = writer.acquire(windowID: windowID) { return el }
        }
        return nil
    }

    /// Polls the writer for an element by CGWindowID, every `pollIntervalMS` up to `reacquireWindowMS`.
    static func reacquire(
        windowID: UInt32, writer: AXFrameWriter, timing: FrameWriteTiming = .standard, sleep: Sleeper
    ) async -> AXWindowElement? {
        let steps = timing.pollIntervalMS > 0 ? timing.reacquireWindowMS / timing.pollIntervalMS : 0
        for i in 0...steps {
            if let el = writer.acquire(windowID: windowID) { return el }
            if i < steps { await sleep(timing.pollIntervalMS) }
        }
        return nil
    }
}

// MARK: - Live implementation

final class LiveAXWindowElement: AXWindowElement {
    private static let enhancedUIAttribute = "AXEnhancedUserInterface"
    private let element: AXUIElement
    private let appElement: AXUIElement

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.appElement = AXUIElementCreateApplication(pid)
    }

    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    func readFrame() -> SnapshotFrame? {
        guard let p = copy(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &pt),
              AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &sz) else { return nil }
        return SnapshotFrame(x: pt.x, y: pt.y, width: sz.width, height: sz.height)
    }

    func disableEnhancedUI() -> Bool {
        guard copy(appElement, Self.enhancedUIAttribute) as? Bool == true else { return false }
        return AXUIElementSetAttributeValue(appElement, Self.enhancedUIAttribute as CFString, kCFBooleanFalse) == .success
    }

    func restoreEnhancedUI() {
        _ = AXUIElementSetAttributeValue(appElement, Self.enhancedUIAttribute as CFString, kCFBooleanTrue)
    }

    private func copy(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success ? v : nil
    }
}

struct LiveAXFrameWriter: AXFrameWriter {
    func acquire(windowID: UInt32) -> AXWindowElement? {
        guard let pid = Self.ownerPID(of: windowID) else { return nil }
        guard let el = AXWindowID.axWindows(pid: pid).first(where: { AXWindowID.windowID(of: $0) == windowID }) else {
            return nil
        }
        return LiveAXWindowElement(element: el, pid: pid)
    }

    private static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let pid = list.first?[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return pid
    }
}
