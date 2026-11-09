// ProblemNotifier.swift
// Posts the "something went wrong" notification. Authorization is requested lazily: never at
// construction or launch, only when the first qualifying problem is due. UNUserNotificationCenter
// sits behind `UserNotificationCentering` so tests never touch the real center.

import Foundation
import UserNotifications

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

/// A plain, Sendable description of the notification to post.
struct ProblemNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let cycleID: UUID

    /// userInfo key carrying the cycle ID (used by the click handler to find the log entry).
    static let cycleIDKey = "cycleID"
}

protocol UserNotificationCentering: Sendable {
    func authorizationStatus() async -> NotificationAuthorization
    /// Asks macOS for alert + sound permission. Returns whether it was granted.
    func requestAuthorization() async throws -> Bool
    func add(_ request: ProblemNotificationRequest) async throws
}

/// The live center. Touches `UNUserNotificationCenter.current()` only inside method calls.
struct LiveUserNotificationCenter: UserNotificationCentering {
    func authorizationStatus() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: ProblemNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = [ProblemNotificationRequest.cycleIDKey: request.cycleID.uuidString]
        let unRequest = UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(unRequest)
    }
}

actor ProblemNotifier {
    private let center: UserNotificationCentering
    private let diagnostics: DiagnosticsRecording
    private var deniedRecorded = false

    /// Nothing happens at construction: no authorization request, no center access.
    init(center: UserNotificationCentering = LiveUserNotificationCenter(),
         diagnostics: DiagnosticsRecording = DiagnosticsLog.shared) {
        self.center = center
        self.diagnostics = diagnostics
    }

    func notify(context: CycleContext, outcome: RestoreOutcome) async {
        guard ProblemNotificationPolicy.shouldNotify(trigger: context.trigger, outcome: outcome) else { return }

        var status = await center.authorizationStatus()
        if status == .notDetermined {
            do {
                status = try await center.requestAuthorization() ? .authorized : .denied
            } catch {
                record("notification-failed", context, ["stage": .string("authorization")])
                return
            }
        }
        switch status {
        case .denied, .notDetermined:
            if !deniedRecorded {
                deniedRecorded = true
                record("notifications-denied", context)
            }
        case .authorized:
            let content = ProblemNotificationPolicy.content(for: outcome)
            let request = ProblemNotificationRequest(
                identifier: "restore-problem-\(context.cycleID.uuidString)",
                title: content.title, body: content.body, cycleID: context.cycleID)
            do {
                try await center.add(request)
                record("notification-posted", context)
            } catch {
                record("notification-failed", context, ["stage": .string("post")])
            }
        }
    }

    private func record(_ name: String, _ context: CycleContext, _ fields: [String: DiagnosticsValue] = [:]) {
        diagnostics.record(DiagnosticsEvent(.notifications, name, cycleID: context.cycleID, fields: fields))
    }
}
