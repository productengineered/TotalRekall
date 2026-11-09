// RestoreLogStore.swift
// Writes the per-window restore log (restore-log.json) atomically under the app support directory.
// "Reveal Restore Log" reads `logURL`/`hasLog`. The directory is injected for tests.

import Foundation

enum RestoreLogError: Error, Equatable {
    case encodingFailed(String)
    case writeFailed(String)
    case readFailed(String)
}

struct RestoreLogStore: Sendable {
    static var defaultDirectory: URL { SnapshotStore.defaultDirectory }

    let directory: URL
    var logURL: URL { directory.appendingPathComponent("restore-log.json") }
    var hasLog: Bool { FileManager.default.fileExists(atPath: logURL.path) }

    init(directory: URL = RestoreLogStore.defaultDirectory) {
        self.directory = directory
    }

    /// Replaces the previous log in one step (temp file + rename): a crash never leaves a torn file.
    func write(_ log: RestoreLog) throws {
        let data: Data
        do {
            data = try Self.encoder().encode(log)
        } catch {
            throw RestoreLogError.encodingFailed(String(describing: error))
        }
        do {
            try SnapshotStore.ensurePrivateDirectory(directory)
            try data.write(to: logURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        } catch {
            throw RestoreLogError.writeFailed(String(describing: error))
        }
    }

    func load() throws -> RestoreLog {
        do {
            return try Self.decoder().decode(RestoreLog.self, from: Data(contentsOf: logURL))
        } catch {
            throw RestoreLogError.readFailed(String(describing: error))
        }
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
