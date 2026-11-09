import Foundation
import ServiceManagement

/// Mirror of `SMAppService.Status` so tests need no ServiceManagement.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Seam over `SMAppService.mainApp`.
protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Real controller. API surface checked against Apple docs for SMAppService
/// (mainApp, status, register(), unregister(), .requiresApproval).
/// [VERIFIED: https://developer.apple.com/documentation/servicemanagement/smappservice]
/// Exact semantics of `.notFound`/`.notRegistered` are [UNVERIFIED] against Apple pages;
/// both are treated as "not enabled", so behavior does not depend on the distinction.
struct SystemLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// What the menu bar view model consumes.
@MainActor
protocol LaunchAtLoginProviding: AnyObject {
    var isEnabled: Bool { get }
    var preferenceEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func selfHeal()
}

/// Launch-at-login preference plus registration, with the FM-9.1 self-heal rule:
/// if the preference says enabled but status != .enabled, re-register.
@MainActor
final class LaunchAtLoginService: LaunchAtLoginProviding {
    static let preferenceKey = "launchAtLoginEnabled"

    private let controller: LoginItemControlling
    private let defaults: UserDefaults

    init(
        controller: LoginItemControlling = SystemLoginItemController(),
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.defaults = defaults
    }

    /// The user's saved intent.
    var preferenceEnabled: Bool { defaults.bool(forKey: Self.preferenceKey) }

    /// Whether the system actually has the login item enabled.
    var isEnabled: Bool { controller.status == .enabled }

    /// Registers or unregisters, then records the preference. The preference is only
    /// updated when the system call succeeds.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if controller.status != .enabled { try controller.register() }
        } else if controller.status != .notRegistered && controller.status != .notFound {
            try controller.unregister()
        }
        defaults.set(enabled, forKey: Self.preferenceKey)
    }

    /// Call at startup. Best effort: a failed re-register leaves the preference intact so
    /// the next launch retries.
    func selfHeal() {
        guard preferenceEnabled, controller.status != .enabled else { return }
        try? controller.register()
    }
}
