// DiagnosticsLog.swift
// The app's private diary. `record(_:)` is nonisolated and non-async: it logs to the unified log,
// stamps the event, and yields it into an AsyncStream drained by the file sink. It never blocks.
// The shared instance starts with the file sink OFF; `startFileSink()` turns it on.

import Foundation
import os
import Synchronization

protocol DiagnosticsRecording: Sendable {
    nonisolated func record(_ event: DiagnosticsEvent)
}

final class DiagnosticsLog: DiagnosticsRecording, Sendable {
    static let subsystem = "com.productengineered.TotalRekall"
    static let shared = DiagnosticsLog()

    private struct State {
        var seq: UInt64 = 0
        var continuation: AsyncStream<DiagnosticsRecord>.Continuation?
        var consumer: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let pid = ProcessInfo.processInfo.processIdentifier

    /// `sink` non-nil turns the file sink on immediately (tests); nil leaves it off.
    init(sink: (any DiagnosticsSink)? = nil) {
        if let sink { attach(sink) }
    }

    /// Turns the file sink on (idempotent). Called from AppDelegate.
    func startFileSink(_ sink: any DiagnosticsSink = DiagnosticsFileSink()) {
        attach(sink)
    }

    nonisolated func record(_ event: DiagnosticsEvent) {
        let logger = Logger(subsystem: Self.subsystem, category: event.category.rawValue)
        let parts = Self.summaryParts(event)
        if event.isFailure {
            logger.error("\(parts.publicText, privacy: .public) \(parts.privateText, privacy: .private)")
        } else {
            logger.notice("\(parts.publicText, privacy: .public) \(parts.privateText, privacy: .private)")
        }
        let ts = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let pid = self.pid
        state.withLock { st in
            st.seq += 1
            st.continuation?.yield(DiagnosticsRecord(ts: ts, seq: st.seq, pid: pid, event: event))
        }
    }

    private func attach(_ sink: any DiagnosticsSink) {
        state.withLock { st in
            guard st.continuation == nil else { return }
            let (stream, continuation) = AsyncStream<DiagnosticsRecord>.makeStream(bufferingPolicy: .unbounded)
            st.continuation = continuation
            st.consumer = Task.detached {
                for await record in stream { await sink.write(record) }
            }
        }
    }

    /// Field keys that identify an app; these only ever reach os.Logger as `.private`.
    nonisolated static let privateFieldKeys: Set<String> = ["bundle_id", "app_name"]

    /// Splits the os.Logger line into a public part and a private part (app identity).
    nonisolated static func summaryParts(_ event: DiagnosticsEvent) -> (publicText: String, privateText: String) {
        func render(_ key: String) -> String {
            switch event.fields[key] {
            case .int(let value): return "\(key)=\(value)"
            case .bool(let value): return "\(key)=\(value)"
            case .double(let value): return "\(key)=\(value)"
            case .string(let value): return "\(key)=\(value)"
            case nil: return key
            }
        }
        let keys = event.fields.keys.sorted()
        let publicKeys = keys.filter { !privateFieldKeys.contains($0) }
        let privateKeys = keys.filter { privateFieldKeys.contains($0) }
        return (([event.name] + publicKeys.map(render)).joined(separator: " "),
                privateKeys.map(render).joined(separator: " "))
    }
}
