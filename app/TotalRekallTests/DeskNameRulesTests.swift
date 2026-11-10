import XCTest
@testable import TotalRekall

/// Shared naming rules (named desks) and the model that applies them.
final class DeskNameRulesTests: XCTestCase {
    func testProblems() {
        let cases: [(raw: String, others: [String], expected: DeskNameRules.Problem?)] = [
            ("", [], .empty),
            ("   \n ", [], .empty),
            ("Studio", [], nil),
            ("Studio", ["Home"], nil),
            ("studio", ["Studio"], .duplicate),
            ("  Studio  ", ["Studio"], .duplicate),
            ("STUDIO", ["studio"], .duplicate),
            ("Café", ["Cafe"], .duplicate),
            ("Cafe", ["Café"], .duplicate),
            ("Desk 1", ["Desk 2"], nil)
        ]
        for item in cases {
            XCTAssertEqual(DeskNameRules.problem(for: item.raw, otherNames: item.others), item.expected,
                           "'\(item.raw)' vs \(item.others)")
        }
    }

    /// A desk may keep its own name: the caller passes every name EXCEPT the one being edited.
    func testDeskMayKeepItsOwnName() {
        let all = ["Studio", "Home"]
        let others = all.filter { $0 != "Studio" }
        XCTAssertNil(DeskNameRules.problem(for: "Studio", otherNames: others))
        XCTAssertNil(DeskNameRules.problem(for: "STUDIO", otherNames: others))
        XCTAssertEqual(DeskNameRules.problem(for: "Home", otherNames: others), .duplicate)
    }

    func testMessages() {
        XCTAssertNil(DeskNameRules.message(for: nil))
        XCTAssertEqual(DeskNameRules.message(for: .empty), "Give this desk a name.")
        XCTAssertEqual(DeskNameRules.message(for: .duplicate), "Another desk already has that name.")
    }

    func testCleanedClampedNormalized() {
        XCTAssertEqual(DeskNameRules.cleaned("  Studio \n"), "Studio")
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(DeskNameRules.clamped(long).count, 40)
        XCTAssertEqual(DeskNameRules.normalized("  " + long + "  ").count, 40)
        // A cap that lands on a space leaves no trailing space.
        let spaced = String(repeating: "a", count: 39) + " b"
        XCTAssertEqual(DeskNameRules.normalized(spaced), String(repeating: "a", count: 39))
    }

    func testDefaultNameIsLowestFree() {
        let cases: [(existing: [String], expected: String)] = [
            ([], "Desk 1"),
            (["Desk 1"], "Desk 2"),
            (["Desk 2"], "Desk 1"),
            (["Desk 1", "Desk 3"], "Desk 2"),
            (["desk 1", " Desk 2 "], "Desk 3"),
            (["Studio", "Home"], "Desk 1")
        ]
        for item in cases {
            XCTAssertEqual(DeskNameRules.defaultName(existing: item.existing), item.expected, "\(item.existing)")
        }
    }
}

@MainActor
final class DeskNameModelTests: XCTestCase {
    private final class Calls {
        var saved: [String] = []
        var cancelled = 0
    }

    private func model(_ text: String, others: [String] = [], calls: Calls) -> DeskNameModel {
        DeskNameModel(mode: .newDesk, initialName: text, otherNames: others,
                      onSave: { calls.saved.append($0) }, onCancel: { calls.cancelled += 1 })
    }

    func testSaveTrimsAndFiresOnce() {
        let calls = Calls()
        let sut = model("  Studio ", calls: calls)
        XCTAssertTrue(sut.canSave)
        sut.save()
        sut.save()
        sut.cancel()
        XCTAssertEqual(calls.saved, ["Studio"])
        XCTAssertEqual(calls.cancelled, 0)
    }

    func testInvalidNameDoesNothing() {
        let calls = Calls()
        let sut = model("studio", others: ["Studio"], calls: calls)
        XCTAssertFalse(sut.canSave)
        XCTAssertEqual(sut.message, "Another desk already has that name.")
        sut.save()
        XCTAssertTrue(calls.saved.isEmpty)
        sut.text = ""
        XCTAssertEqual(sut.message, "Give this desk a name.")
        sut.cancel()
        sut.cancel()
        XCTAssertEqual(calls.cancelled, 1)
    }
}
