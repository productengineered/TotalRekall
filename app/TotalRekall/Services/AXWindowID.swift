// AXWindowID.swift
// Joins an AXUIElement to its CGWindowID via the private `_AXUIElementGetWindow`.
// PRIVATE API: `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)`, resolved with dlsym
// so a missing symbol degrades to nil instead of a link error. Proven on real hardware
// (proven on macOS 27.0, 26A428). Only SpaceBridge.swift and this file reference private symbols.

import ApplicationServices
import Foundation

enum AXWindowID {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let symbolName = "_AXUIElementGetWindow"

    // PRIVATE API: dlsym lookup.
    private static let getWindow: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let ptr = dlsym(handle, symbolName) else { return nil }
        return unsafeBitCast(ptr, to: GetWindowFn.self)
    }()

    /// True when the private symbol resolved on this macOS build.
    static var isAvailable: Bool { getWindow != nil }

    /// CGWindowID for an AX window element, or nil when unresolvable or unsupported.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindow else { return nil }
        var wid: CGWindowID = 0
        guard fn(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// The app's AX windows, with a per-app messaging timeout so one hung app cannot stall us.
    static func axWindows(pid: pid_t, timeout: Float = 1.0) -> [AXUIElement] {
        copyWindows(pid: pid, timeout: timeout).windows
    }

    /// Same read as `axWindows`, plus the AXError when the windows attribute could not be read
    /// (`nil` on success). The code goes to the diagnostics trail so an empty AX join explains itself.
    static func copyWindows(pid: pid_t, timeout: Float = 1.0) -> (windows: [AXUIElement], error: AXError?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else { return ([], result) }
        return (value as? [AXUIElement] ?? [], nil)
    }
}
