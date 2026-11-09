import XCTest
@testable import TotalRekall

private final class FakeLoginItem: LoginItemControlling {
    var status: LoginItemStatus
    var registerCalls = 0
    var unregisterCalls = 0
    var registerError: Error?
    init(_ status: LoginItemStatus) { self.status = status }
    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = .enabled
    }
    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

private struct RegisterFailure: Error {}

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "LaunchAtLoginServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testEnableRegistersAndStoresPreference() throws {
        let item = FakeLoginItem(.notRegistered)
        let sut = LaunchAtLoginService(controller: item, defaults: defaults)
        try sut.setEnabled(true)
        XCTAssertEqual(item.registerCalls, 1)
        XCTAssertTrue(sut.isEnabled)
        XCTAssertTrue(sut.preferenceEnabled)
    }

    func testDisableUnregistersAndClearsPreference() throws {
        let item = FakeLoginItem(.enabled)
        let sut = LaunchAtLoginService(controller: item, defaults: defaults)
        try sut.setEnabled(true)
        try sut.setEnabled(false)
        XCTAssertEqual(item.unregisterCalls, 1)
        XCTAssertFalse(sut.isEnabled)
        XCTAssertFalse(sut.preferenceEnabled)
    }

    func testFailedRegisterDoesNotStorePreference() {
        let item = FakeLoginItem(.notRegistered)
        item.registerError = RegisterFailure()
        let sut = LaunchAtLoginService(controller: item, defaults: defaults)
        XCTAssertThrowsError(try sut.setEnabled(true))
        XCTAssertFalse(sut.preferenceEnabled)
    }

    func testSelfHealReRegistersWhenPreferenceEnabledButStatusNot() throws {
        let item = FakeLoginItem(.notRegistered)
        defaults.set(true, forKey: LaunchAtLoginService.preferenceKey)
        let sut = LaunchAtLoginService(controller: item, defaults: defaults)
        sut.selfHeal()
        XCTAssertEqual(item.registerCalls, 1)
        XCTAssertTrue(sut.isEnabled)
    }

    func testSelfHealNoOpWhenAlreadyEnabledOrPreferenceOff() {
        let enabled = FakeLoginItem(.enabled)
        defaults.set(true, forKey: LaunchAtLoginService.preferenceKey)
        LaunchAtLoginService(controller: enabled, defaults: defaults).selfHeal()
        XCTAssertEqual(enabled.registerCalls, 0)

        let off = FakeLoginItem(.notRegistered)
        defaults.set(false, forKey: LaunchAtLoginService.preferenceKey)
        LaunchAtLoginService(controller: off, defaults: defaults).selfHeal()
        XCTAssertEqual(off.registerCalls, 0)
    }

    func testSelfHealSwallowsRegisterFailureAndKeepsPreference() {
        let item = FakeLoginItem(.requiresApproval)
        item.registerError = RegisterFailure()
        defaults.set(true, forKey: LaunchAtLoginService.preferenceKey)
        let sut = LaunchAtLoginService(controller: item, defaults: defaults)
        sut.selfHeal()
        XCTAssertTrue(sut.preferenceEnabled)
        XCTAssertFalse(sut.isEnabled)
    }
}
