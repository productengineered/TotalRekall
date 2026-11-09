// DiagnosticsExporter.swift
// Turns the sanitized diagnostics bundle into one zip on the Desktop (or, when the Desktop cannot be
// written, in the app's own exports folder). Runs off the main actor; the staging folder is private
// (0700) and always removed. Events carry sizes, counts and reason codes only, never paths or titles.

import AppKit
import Foundation
import Synchronization

// MARK: - Seams

protocol DiagnosticsBundleBuilding: Sendable {
    func build(into folder: URL) async throws -> DiagnosticsManifest
}

extension DiagnosticsBundleBuilder: DiagnosticsBundleBuilding {}

/// Zips a folder into a single file. The real one shells out to /usr/bin/ditto.
protocol FolderZipping: Sendable {
    func zip(folder: URL, to destination: URL) async throws
}

/// Shows a file in Finder.
@MainActor
protocol FileRevealing: AnyObject {
    func reveal(_ url: URL)
}

@MainActor
final class WorkspaceFileRevealer: FileRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum DiagnosticsExportResult: Equatable, Sendable {
    case desktop(URL)
    case fallback(URL)
    case failed
}

protocol DiagnosticsExporting: Sendable {
    func export() async -> DiagnosticsExportResult
}

/// Inert exporter for previews and tests that do not export.
struct StubDiagnosticsExporter: DiagnosticsExporting {
    func export() async -> DiagnosticsExportResult { .failed }
}

enum DiagnosticsExportError: Error, Equatable {
    case zipFailed
    case zipTimedOut
    case stagingFailed
    case simulated
}

/// DEBUG-only failure injection (launch argument `-TRSimulateExportFailure desktop|all`).
enum SimulatedExportFailure: String, Sendable {
    case desktop
    case all
}

// MARK: - Zipper

struct DittoZipper: FolderZipping {
    static let defaultTimeout: TimeInterval = 60
    var timeout: TimeInterval = DittoZipper.defaultTimeout
    /// Overridable so tests can substitute a hanging process; production always uses ditto.
    var executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    var makeArguments: @Sendable (URL, URL) -> [String] = { folder, destination in
        ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path]
    }

    /// Single source of truth for the outcome. A process that exited normally with status 0 is a
    /// success even if the watchdog fired in the same instant; only a process the watchdog killed
    /// (terminated by signal while the watchdog had fired) counts as a timeout.
    static func outcome(reason: Process.TerminationReason, status: Int32,
                        watchdogFired: Bool) -> DiagnosticsExportError? {
        if reason == .exit && status == 0 { return nil }
        if watchdogFired && reason == .uncaughtSignal { return .zipTimedOut }
        return .zipFailed
    }

    func zip(folder: URL, to destination: URL) async throws {
        let timeout = self.timeout
        let executableURL = self.executableURL
        let arguments = makeArguments(folder, destination)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let watchdogFired = Mutex(false)
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DiagnosticsExportError.zipFailed)
                    return
                }
                // The watchdog only terminates, and records that it did so only if the process was
                // still running when it looked.
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    watchdogFired.withLock { $0 = true }
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                process.waitUntilExit()
                watchdog.cancel()
                let fired = watchdogFired.withLock { $0 }
                if let error = Self.outcome(reason: process.terminationReason,
                                            status: process.terminationStatus, watchdogFired: fired) {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Exporter

struct DiagnosticsExporter: DiagnosticsExporting {
    let builder: any DiagnosticsBundleBuilding
    let zipper: any FolderZipping
    let recorder: any DiagnosticsRecording
    let desktopDirectory: URL
    let fallbackDirectory: URL
    let stagingRoot: URL
    var now: @Sendable () -> Date = { Date() }
    var simulatedFailure: SimulatedExportFailure?
    var artificialDelay: Duration?

    static let folderPrefix = "TotalRekall-Diagnostics-"

    init(builder: any DiagnosticsBundleBuilding,
         zipper: any FolderZipping = DittoZipper(),
         recorder: any DiagnosticsRecording = DiagnosticsLog.shared,
         desktopDirectory: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0],
         fallbackDirectory: URL = DiagnosticsExporter.defaultFallbackDirectory,
         stagingRoot: URL = FileManager.default.temporaryDirectory,
         now: @escaping @Sendable () -> Date = { Date() },
         simulatedFailure: SimulatedExportFailure? = nil,
         artificialDelay: Duration? = nil) {
        self.builder = builder
        self.zipper = zipper
        self.recorder = recorder
        self.desktopDirectory = desktopDirectory
        self.fallbackDirectory = fallbackDirectory
        self.stagingRoot = stagingRoot
        self.now = now
        self.simulatedFailure = simulatedFailure
        self.artificialDelay = artificialDelay
    }

    static var defaultFallbackDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TotalRekall", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
    }

    func export() async -> DiagnosticsExportResult {
        let started = ContinuousClock.now
        recorder.record(DiagnosticsEvent(.export, "export-started"))
        let fm = FileManager.default
        let stamp = Self.stamp(now())
        let folderName = Self.folderPrefix + stamp
        let stagingParent = stagingRoot.appendingPathComponent("TotalRekall-export-\(UUID().uuidString)",
                                                               isDirectory: true)
        defer { try? fm.removeItem(at: stagingParent) }

        let manifest: DiagnosticsManifest
        let staging = stagingParent.appendingPathComponent(folderName, isDirectory: true)
        do {
            try fm.createDirectory(at: stagingParent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            manifest = try await builder.build(into: staging)
        } catch {
            return fail(reason: "staging")
        }

        if let artificialDelay { try? await Task.sleep(for: artificialDelay) }

        var usedFallback = false
        var written: URL?
        if simulatedFailure == nil {
            written = await tryZip(staging: staging, directory: desktopDirectory, stamp: stamp)
        }
        if written == nil {
            usedFallback = true
            if simulatedFailure != .all {
                written = await tryZip(staging: staging, directory: fallbackDirectory, stamp: stamp)
            }
        }
        guard let zip = written else { return fail(reason: "zip") }

        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        let ms = Self.milliseconds(since: started)
        if usedFallback {
            recorder.record(DiagnosticsEvent(.export, "export-fallback", fields: ["reason": .string("desktop")]))
        }
        recorder.record(DiagnosticsEvent(.export, "export-finished", fields: [
            "bytes": .int(size), "files": .int(manifest.filesIncluded.count), "ms": .int(ms),
            "fallback": .bool(usedFallback)
        ]))
        return usedFallback ? .fallback(zip) : .desktop(zip)
    }

    // MARK: Helpers

    private func tryZip(staging: URL, directory: URL, stamp: String) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: directory == fallbackDirectory ? [.posixPermissions: 0o700] : nil)
            let destination = uniqueDestination(in: directory, stamp: stamp)
            do {
                try await zipper.zip(folder: staging, to: destination)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return destination
            } catch {
                try? fm.removeItem(at: destination)
                return nil
            }
        } catch {
            return nil
        }
    }

    private func uniqueDestination(in directory: URL, stamp: String) -> URL {
        let fm = FileManager.default
        let base = Self.folderPrefix + stamp
        var candidate = directory.appendingPathComponent(base + ".zip")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path), suffix < 1000 {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).zip")
            suffix += 1
        }
        return candidate
    }

    private func fail(reason: String) -> DiagnosticsExportResult {
        recorder.record(DiagnosticsEvent(.export, "export-failed", fields: ["reason": .string(reason)]))
        return .failed
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
