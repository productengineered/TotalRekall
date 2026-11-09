// DiagnosticsFileSink.swift
// Append-only JSONL file with size-based rotation (diagnostics.jsonl -> .1 -> .2), kept private:
// folder 0700, files 0600. Write errors are logged once and never thrown to callers.

import Foundation
import os

/// A destination for stamped diagnostics records.
protocol DiagnosticsSink: Sendable {
    func write(_ record: DiagnosticsRecord) async
}

/// An event stamped at `record()` time (timestamp + per-process sequence number).
struct DiagnosticsRecord: Sendable, Equatable, Encodable {
    let ts: String
    let seq: UInt64
    let pid: Int32
    let event: DiagnosticsEvent

    private enum CodingKeys: String, CodingKey { case ts, seq, pid, category, event, cycleID, fields }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(seq, forKey: .seq)
        try c.encode(pid, forKey: .pid)
        try c.encode(event.category, forKey: .category)
        try c.encode(event.name, forKey: .event)
        try c.encode(event.cycleID?.uuidString, forKey: .cycleID)
        try c.encode(event.fields, forKey: .fields)
    }
}

actor DiagnosticsFileSink: DiagnosticsSink {
    static let maxFileBytes = 5_000_000
    static let maxFiles = 3

    static var defaultDirectory: URL {
        SnapshotStore.defaultDirectory.appendingPathComponent("diagnostics", isDirectory: true)
    }

    nonisolated let directory: URL
    private let maxBytes: Int
    private let fileLimit: Int
    private var currentSize: Int?
    private var reportedError = false
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "com.productengineered.TotalRekall", category: "diagnostics-sink")

    init(directory: URL = DiagnosticsFileSink.defaultDirectory,
         maxFileBytes: Int = DiagnosticsFileSink.maxFileBytes,
         maxFiles: Int = DiagnosticsFileSink.maxFiles) {
        self.directory = directory
        self.maxBytes = maxFileBytes
        self.fileLimit = max(1, maxFiles)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = e
    }

    nonisolated func fileURL(index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "diagnostics.jsonl" : "diagnostics.\(index).jsonl")
    }

    func write(_ record: DiagnosticsRecord) async {
        do {
            var line = try encoder.encode(record)
            line.append(0x0A)
            try append(line)
        } catch {
            if !reportedError {
                reportedError = true
                logger.error("diagnostics file write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func append(_ line: Data) throws {
        try SnapshotStore.ensurePrivateDirectory(directory)
        let fm = FileManager.default
        let url = fileURL(index: 0)
        var size = currentSize ?? 0
        if currentSize == nil, let attrs = try? fm.attributesOfItem(atPath: url.path),
           let existing = attrs[.size] as? Int {
            size = existing
        }
        if size > 0, size + line.count > maxBytes {
            try rotate()
            size = 0
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        currentSize = size + line.count
    }

    /// Deletes the oldest, shifts the rest up (.1 -> .2, current -> .1).
    private func rotate() throws {
        let fm = FileManager.default
        let oldest = fileLimit - 1
        if oldest >= 1 {
            let last = fileURL(index: oldest)
            if fm.fileExists(atPath: last.path) { try fm.removeItem(at: last) }
            var i = oldest - 1
            while i >= 1 {
                let src = fileURL(index: i)
                if fm.fileExists(atPath: src.path) { try fm.moveItem(at: src, to: fileURL(index: i + 1)) }
                i -= 1
            }
            try fm.moveItem(at: fileURL(index: 0), to: fileURL(index: 1))
        } else {
            try fm.removeItem(at: fileURL(index: 0))
        }
        currentSize = 0
    }
}
