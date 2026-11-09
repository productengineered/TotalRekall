// WindowRestorer.swift
// Executes a RestorePlan: grouped Space moves first, then verified AX frame writes, with
// bring-to-current for windows AX cannot reach. Proven live on real hardware.
// Matching is by CGWindowID only (carried in the plan). System calls sit behind WindowSpaceMoving
// and AXFrameWriter so every branch is testable with fakes.

import CoreGraphics
import Foundation

/// The slice of SpaceBridge the restorer needs.
protocol WindowSpaceMoving: Sendable {
    func spaceIDs(forWindows windowIDs: [CGWindowID]) async throws -> [UInt64]
    /// Submits the move and confirms it; throws if not confirmed.
    func moveWindows(_ windowIDs: [CGWindowID], toSpaceID spaceID: UInt64) async throws
    func currentSpaceID(onDisplayContaining spaceID: UInt64) async throws -> UInt64?
}

extension SpaceBridge: WindowSpaceMoving {}

protocol WindowRestoring: Sendable {
    func execute(_ plan: RestorePlan) async -> [RestoreWindowResult]
}

actor WindowRestorer: WindowRestoring {
    private let spaces: WindowSpaceMoving
    private let writer: AXFrameWriter
    private let timing: FrameWriteTiming
    private let sleep: VerifiedFrameWriter.Sleeper

    init(
        spaces: WindowSpaceMoving,
        writer: AXFrameWriter = LiveAXFrameWriter(),
        timing: FrameWriteTiming = .standard,
        sleep: @escaping VerifiedFrameWriter.Sleeper = { ms in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
    ) {
        self.spaces = spaces
        self.writer = writer
        self.timing = timing
        self.sleep = sleep
    }

    func execute(_ plan: RestorePlan) async -> [RestoreWindowResult] {
        var byID: [UUID: RestoreWindowResult] = [:]
        for w in plan.windows {
            if let r = RestoreWindowResult.fromPlanOnly(w) { byID[w.snapshotID] = r }
        }

        // Phase 1: Space moves, grouped per target desktop. Always before any frame set.
        var moveFailures: [UInt32: String] = [:]
        for group in plan.spaceMoveGroups {
            moveFailures.merge(await moveGroup(group)) { first, _ in first }
        }

        // Phase 2: per-window work, in plan order.
        for w in plan.windows where byID[w.snapshotID] == nil {
            byID[w.snapshotID] = await run(w, moveFailures: moveFailures)
        }
        return plan.windows.compactMap { byID[$0.snapshotID] }
    }

    // MARK: - Space moves

    /// Moves one group and returns failure reasons for windows that stayed unconfirmed.
    private func moveGroup(_ group: SpaceMoveGroup) async -> [UInt32: String] {
        do {
            try await spaces.moveWindows(group.windowIDs, toSpaceID: group.spaceID)
            return [:]
        } catch SpaceBridgeError.positionOnlyMode(let reason) {
            return Dictionary(uniqueKeysWithValues: group.windowIDs.map { ($0, "position-only mode: \(reason)") })
        } catch {
            // Fall through: confirm per window, retry the unconfirmed ones individually once.
        }
        var failures: [UInt32: String] = [:]
        for wid in group.windowIDs {
            if await isOn(group.spaceID, wid) { continue }
            if await moveConfirmed(wid, to: group.spaceID) { continue }
            failures[wid] = "Space move unconfirmed"
        }
        return failures
    }

    private func isOn(_ spaceID: UInt64, _ windowID: UInt32) async -> Bool {
        guard let ids = try? await spaces.spaceIDs(forWindows: [windowID]) else { return false }
        return !ids.isEmpty && ids.allSatisfy { $0 == spaceID }
    }

    private func moveConfirmed(_ windowID: UInt32, to spaceID: UInt64) async -> Bool {
        do {
            try await spaces.moveWindows([windowID], toSpaceID: spaceID)
            return true
        } catch {
            return await isOn(spaceID, windowID)
        }
    }

    // MARK: - Per-window execution

    private func run(_ w: PlannedWindow, moveFailures: [UInt32: String]) async -> RestoreWindowResult {
        guard let wid = w.windowID else { return RestoreWindowResult(planned: w, status: .skipped(.notFound)) }
        switch w.action {
        case .alreadyCorrect:
            return RestoreWindowResult(planned: w, status: .alreadyCorrect)
        case .skip(let reason):
            return RestoreWindowResult(planned: w, status: .skipped(reason))
        case .frameFix(let frame):
            return await applyFrame(frame, to: w, windowID: wid)
        case .moveSpace(_, _, let frame):
            if let reason = moveFailures[wid] { return RestoreWindowResult(planned: w, status: .failed, detail: reason) }
            guard let frame else { return RestoreWindowResult(planned: w, status: .spaceMoved) }
            return await applyFrame(frame, to: w, windowID: wid, afterSpaceMove: true)
        case .bringToCurrent(let returnSpaceID, let frame):
            return await bringToCurrent(w, windowID: wid, returnSpaceID: returnSpaceID, frame: frame)
        }
    }

    /// Re-acquires the AX element by CGWindowID, then writes and verifies the frame.
    private func applyFrame(
        _ frame: SnapshotFrame, to w: PlannedWindow, windowID: UInt32, afterSpaceMove: Bool = false
    ) async -> RestoreWindowResult {
        guard let element = await Self.reacquire(
            windowID, afterSpaceMove: afterSpaceMove, writer: writer, timing: timing, sleep: sleep
        ) else {
            return RestoreWindowResult(planned: w, status: .axUnreachable, detail: "AX cannot see window")
        }
        return Self.result(for: w, after: await VerifiedFrameWriter.write(frame, to: element, timing: timing, sleep: sleep))
    }

    /// Nonisolated and static so the element stays in a disconnected region (AXWindowElement is not Sendable).
    private static func reacquire(
        _ windowID: UInt32, afterSpaceMove: Bool, writer: AXFrameWriter, timing: FrameWriteTiming,
        sleep: VerifiedFrameWriter.Sleeper
    ) async -> AXWindowElement? {
        if afterSpaceMove {
            return await VerifiedFrameWriter.reacquireAfterSpaceMove(
                windowID: windowID, writer: writer, timing: timing, sleep: sleep
            )
        }
        return await VerifiedFrameWriter.reacquire(windowID: windowID, writer: writer, timing: timing, sleep: sleep)
    }

    private static func result(for w: PlannedWindow, after write: VerifiedFrameWrite) -> RestoreWindowResult {
        let actual = write.actual.map { "actual \(describe($0))" } ?? "frame unreadable"
        let detail = "\(actual), attempts \(write.attempts)"
        if write.verified { return RestoreWindowResult(planned: w, status: .moved, detail: detail) }
        if write.actual == nil && !(write.positionOK && write.sizeOK) {
            return RestoreWindowResult(planned: w, status: .failed, detail: detail)
        }
        return RestoreWindowResult(planned: w, status: .movedUnverified, detail: detail)
    }

    private static func describe(_ f: SnapshotFrame) -> String {
        "(\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height)))"
    }

    // MARK: - Bring to current

    /// 1. pull to the display's current Space  2. re-acquire AX (backoff)  3. verified frame  4. move to target.
    /// If AX still cannot see the window, it is moved back to its original desktop and that move is
    /// confirmed. Only a confirmed move-back reports ax-unreachable (left in place); otherwise `failed`.
    private func bringToCurrent(
        _ w: PlannedWindow, windowID wid: UInt32, returnSpaceID: UInt64?, frame: SnapshotFrame
    ) async -> RestoreWindowResult {
        guard let origin = (try? await spaces.spaceIDs(forWindows: [wid]))?.first,
              let bring = (try? await spaces.currentSpaceID(onDisplayContaining: origin)) ?? nil else {
            return RestoreWindowResult(planned: w, status: .failed, detail: "current Space unknown")
        }
        var broughtOver = false
        if origin != bring {
            guard await moveConfirmed(wid, to: bring) else {
                if !(await isOn(origin, wid)) { _ = await moveConfirmed(wid, to: origin) }
                return RestoreWindowResult(planned: w, status: .failed, detail: "bring-to-current unconfirmed")
            }
            broughtOver = true
        }

        guard let element = await Self.reacquire(
            wid, afterSpaceMove: broughtOver, writer: writer, timing: timing, sleep: sleep
        ) else {
            guard broughtOver else {
                return RestoreWindowResult(planned: w, status: .axUnreachable,
                                           detail: "AX cannot see window; left on its desktop")
            }
            guard await moveConfirmed(wid, to: origin) else {
                return RestoreWindowResult(planned: w, status: .failed,
                                           detail: "AX cannot see window after bring-to-current; "
                                               + "return to original desktop unconfirmed")
            }
            return RestoreWindowResult(planned: w, status: .axUnreachable,
                                       detail: "AX cannot see window after bring-to-current; "
                                           + "returned to original desktop (confirmed)")
        }
        let written = await VerifiedFrameWriter.write(frame, to: element, timing: timing, sleep: sleep)
        var result = Self.result(for: w, after: written)

        let destination = returnSpaceID ?? origin
        if destination != bring, !(await moveConfirmed(wid, to: destination)) {
            result = RestoreWindowResult(planned: w, status: .failed, detail: "final Space move unconfirmed")
        }
        return result
    }
}
