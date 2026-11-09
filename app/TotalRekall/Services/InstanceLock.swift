import Darwin
import Foundation

/// Single-instance guard backed by an exclusive, non-blocking `flock` on a lock file.
///
/// The file descriptor is held for the life of the process (or until `release()`), because
/// `flock` locks belong to the open file description. A second `InstanceLock` on the same
/// path opens its own descriptor, so its `tryAcquire()` fails while the first holds the lock.
final class InstanceLock {
    private let url: URL
    private var fileDescriptor: Int32 = -1

    /// Default lock file: ~/Library/Application Support/TotalRekall/instance.lock
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TotalRekall", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    init(url: URL = InstanceLock.defaultURL) {
        self.url = url
    }

    deinit {
        release()
    }

    var isHeld: Bool { fileDescriptor >= 0 }

    /// Creates the directory (0700) and lock file (0600) if needed, then takes LOCK_EX | LOCK_NB.
    /// Returns true if this instance now holds the lock (also true if it already did).
    @discardableResult
    func tryAcquire() -> Bool {
        if isHeld { return true }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        fileDescriptor = descriptor
        return true
    }

    /// Releases the lock and closes the descriptor. Safe to call when not held.
    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }
}
