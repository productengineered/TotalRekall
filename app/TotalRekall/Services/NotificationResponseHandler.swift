// NotificationResponseHandler.swift
// The UNUserNotificationCenter delegate. A click on a problem notification reveals restore-log.json
// in Finder (or the diagnostics folder when no log exists). The app is an accessory app and is
// rarely frontmost, so notifications are presented as banner + list even in the foreground.

import Foundation
import UserNotifications

@MainActor
final class NotificationResponseHandler: NSObject, UNUserNotificationCenterDelegate {
    private let logURL: URL
    private let diagnosticsDirectory: URL
    private let revealer: FileRevealing
    private let fileExists: @Sendable (URL) -> Bool
    private let diagnostics: DiagnosticsRecording

    init(logURL: URL = RestoreLogStore().logURL,
         diagnosticsDirectory: URL = DiagnosticsFileSink.defaultDirectory,
         revealer: FileRevealing = WorkspaceFileRevealer(),
         fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         diagnostics: DiagnosticsRecording = DiagnosticsLog.shared) {
        self.logURL = logURL
        self.diagnosticsDirectory = diagnosticsDirectory
        self.revealer = revealer
        self.fileExists = fileExists
        self.diagnostics = diagnostics
        super.init()
    }

    /// Reveals the restore log, or the diagnostics folder when the log does not exist yet.
    func handleClick(cycleID: UUID?) {
        let target: String
        if fileExists(logURL) {
            revealer.reveal(logURL)
            target = "restore-log"
        } else {
            revealer.reveal(diagnosticsDirectory)
            target = "diagnostics-folder"
        }
        diagnostics.record(DiagnosticsEvent(.notifications, "notification-clicked", cycleID: cycleID,
                                            fields: ["revealed": .string(target)]))
    }

    /// Banner + list so a problem is visible even when the app counts as frontmost.
    nonisolated static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list]

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.presentationOptions
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let idString = response.notification.request.content.userInfo[ProblemNotificationRequest.cycleIDKey] as? String
        let cycleID = idString.flatMap(UUID.init(uuidString:))
        await MainActor.run { handleClick(cycleID: cycleID) }
    }
}
