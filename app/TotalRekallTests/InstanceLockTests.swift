import XCTest
@testable import TotalRekall

final class InstanceLockTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("TotalRekall", isDirectory: true)
        lockURL = directory.appendingPathComponent("instance.lock")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    func testSecondAcquireOnSamePathFails() {
        let first = InstanceLock(url: lockURL)
        let second = InstanceLock(url: lockURL)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertFalse(second.tryAcquire())
        XCTAssertFalse(second.isHeld)
    }

    func testAcquireSucceedsAfterRelease() {
        let first = InstanceLock(url: lockURL)
        XCTAssertTrue(first.tryAcquire())
        first.release()
        let second = InstanceLock(url: lockURL)
        XCTAssertTrue(second.tryAcquire())
    }

    func testReacquireOnSameInstanceIsIdempotent() {
        let lock = InstanceLock(url: lockURL)
        XCTAssertTrue(lock.tryAcquire())
        XCTAssertTrue(lock.tryAcquire())
    }

    func testDirectoryAndFileAreOwnerOnly() throws {
        let lock = InstanceLock(url: lockURL)
        XCTAssertTrue(lock.tryAcquire())
        let dirPerms = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let filePerms = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        XCTAssertEqual(filePerms, 0o600)
    }

    func testReleaseWhenNotHeldIsSafe() {
        let lock = InstanceLock(url: lockURL)
        lock.release()
        XCTAssertFalse(lock.isHeld)
    }
}
