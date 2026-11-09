import Foundation
import Synchronization
@testable import TotalRekall

/// In-memory `DiagnosticsRecording` for tests.
final class RecordingDiagnostics: DiagnosticsRecording, Sendable {
    private let storage = Mutex<[DiagnosticsEvent]>([])
    var events: [DiagnosticsEvent] { storage.withLock { $0 } }
    nonisolated func record(_ event: DiagnosticsEvent) { storage.withLock { $0.append(event) } }
}
