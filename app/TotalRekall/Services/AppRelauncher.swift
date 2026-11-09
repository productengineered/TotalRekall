import AppKit

/// Relaunches the app bundle after this instance exits. Used when macOS keeps a stale per-process
/// Accessibility trust value after a re-grant: a fresh process reads the current TCC state.
///
/// The new copy is started by a detached `/bin/sh` that waits for this PID to exit first, so the
/// InstanceLock is free when the new instance starts.
struct AppRelauncher {
    let bundleURL: URL
    let processID: Int32

    init(bundleURL: URL = Bundle.main.bundleURL, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.bundleURL = bundleURL
        self.processID = processID
    }

    /// `/bin/sh -c <script> sh <pid> <bundle path>`: paths travel as positional arguments, never
    /// interpolated into the script, so spaces or quotes in the path are safe.
    static let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\""

    var arguments: [String] {
        ["-c", Self.script, "sh", String(processID), bundleURL.path]
    }

    /// Starts the waiter, then quits. Returns false (and does not quit) if the waiter could not start.
    @MainActor
    @discardableResult
    func relaunch(terminate: @MainActor () -> Void = { NSApp.terminate(nil) }) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return false
        }
        terminate()
        return true
    }
}
