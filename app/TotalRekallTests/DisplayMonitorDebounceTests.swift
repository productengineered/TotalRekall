import CoreGraphics
import XCTest
@testable import TotalRekall

private actor EventCollector {
    private(set) var events: [DisplayChangeEvent] = []
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<DisplayChangeEvent>) {
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
    }

    private func append(_ event: DisplayChangeEvent) { events.append(event) }
    func stop() { task?.cancel() }
}

final class DisplayMonitorDebounceTests: XCTestCase {
    private let window = Duration.milliseconds(1500)

    private func makeEvent(_ id: UInt32, _ flags: CGDisplayChangeSummaryFlags, vendor: UInt32 = 0x10AC) -> RawDisplayEvent {
        RawDisplayEvent(displayID: id, flags: flags.rawValue, vendorID: vendor, source: .reconfigurationCallback)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    /// Lets in-flight actor hops drain so "nothing happened" assertions are meaningful (no real sleep).
    private func settleScheduler() async {
        for _ in 0..<500 { await Task.yield() }
    }

    private struct Rig {
        let monitor: DisplayMonitor
        let clock: TestClock
        let collector: EventCollector
    }

    private func makeRig() async -> Rig {
        let clock = TestClock()
        let monitor = DisplayMonitor(debounce: window, clock: clock)
        let collector = EventCollector()
        await collector.start(monitor.events)
        await monitor.startProcessing()
        return Rig(monitor: monitor, clock: clock, collector: collector)
    }

    func testBurstCollapsesToOneEvent() async {
        let rig = await makeRig()
        let burst: [CGDisplayChangeSummaryFlags] = [
            .beginConfigurationFlag, .beginConfigurationFlag, .beginConfigurationFlag,
            .desktopShapeChangedFlag, .desktopShapeChangedFlag, [.movedFlag, .desktopShapeChangedFlag]
        ]
        for flags in burst { XCTAssertTrue(rig.monitor.receive(makeEvent(7, flags))) }
        let ingested = await waitUntil { await rig.monitor.ingestedCount == burst.count }
        XCTAssertTrue(ingested)
        let armed = await waitUntil { await rig.clock.hasSleeper(deadline: self.window) }
        XCTAssertTrue(armed)
        XCTAssertTrue(rig.monitor.isChangeInProgress)

        await rig.clock.advance(by: window)
        let emitted = await waitUntil { await rig.collector.events.count == 1 }
        XCTAssertTrue(emitted)
        await settleScheduler()

        let events = await rig.collector.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.moved, [7])
        XCTAssertEqual(events.first?.rawEventCount, burst.count)
        XCTAssertFalse(rig.monitor.isChangeInProgress)
        await rig.collector.stop()
    }

    func testGapUnderWindowExtendsDebounce() async {
        let rig = await makeRig()
        rig.monitor.receive(makeEvent(1, .addFlag))
        let first = await waitUntil { await rig.clock.hasSleeper(deadline: self.window) }
        XCTAssertTrue(first)

        await rig.clock.advance(by: .milliseconds(1000))
        rig.monitor.receive(makeEvent(2, .removeFlag))
        let second = await waitUntil { await rig.clock.hasSleeper(deadline: .milliseconds(2500)) }
        XCTAssertTrue(second)

        // 2000 ms since the first event, but only 1000 ms since the second: still pending.
        await rig.clock.advance(by: .milliseconds(1000))
        await settleScheduler()
        var events = await rig.collector.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(rig.monitor.isChangeInProgress)

        await rig.clock.advance(by: .milliseconds(500))
        let emitted = await waitUntil { await rig.collector.events.count == 1 }
        XCTAssertTrue(emitted)
        events = await rig.collector.events
        XCTAssertEqual(events.first?.added, [1])
        XCTAssertEqual(events.first?.removed, [2])
        XCTAssertFalse(rig.monitor.isChangeInProgress)
        await rig.collector.stop()
    }

    func testSuppressionIgnoresEvents() async {
        let rig = await makeRig()
        rig.monitor.beginSelfChange()
        XCTAssertFalse(rig.monitor.receive(makeEvent(3, .movedFlag)))
        XCTAssertFalse(rig.monitor.isChangeInProgress)
        rig.monitor.endSelfChange()
        await settleScheduler()

        let ingested = await rig.monitor.ingestedCount
        XCTAssertEqual(ingested, 0)
        let hasSleeper = await rig.clock.hasSleeper(deadline: window)
        XCTAssertFalse(hasSleeper)

        XCTAssertTrue(rig.monitor.receive(makeEvent(3, .movedFlag)), "events after endSelfChange are accepted")
        await rig.collector.stop()
    }

    func testNestedSuppressionRequiresMatchingEnds() async {
        let rig = await makeRig()
        rig.monitor.beginSelfChange()
        rig.monitor.beginSelfChange()
        XCTAssertEqual(rig.monitor.suppressionDepth, 2)
        rig.monitor.endSelfChange()
        XCTAssertEqual(rig.monitor.suppressionDepth, 1)
        XCTAssertFalse(rig.monitor.receive(makeEvent(4, .movedFlag)), "still suppressed at depth 1")
        rig.monitor.endSelfChange()
        XCTAssertEqual(rig.monitor.suppressionDepth, 0)
        XCTAssertTrue(rig.monitor.receive(makeEvent(4, .movedFlag)))

        rig.monitor.endSelfChange()  // unbalanced end must not go negative
        XCTAssertEqual(rig.monitor.suppressionDepth, 0)
        await rig.collector.stop()
    }

    func testZeroVendorDisplaysAreIgnoredExceptRemovals() async {
        let rig = await makeRig()
        XCTAssertFalse(rig.monitor.receive(makeEvent(9, .addFlag, vendor: 0)))
        XCTAssertFalse(rig.monitor.isChangeInProgress)
        XCTAssertTrue(rig.monitor.receive(makeEvent(9, .removeFlag, vendor: 0)))
        XCTAssertTrue(rig.monitor.receive(.screenParametersChanged()))
        await rig.collector.stop()
    }

    /// The raw callback closes the snapshot gate synchronously (before any debounce or actor hop);
    /// self-suppressed and transient zero-vendor callbacks never touch it. Fully synchronous: no
    /// processing task, no clock.
    func testReceiveClosesSnapshotGateSynchronouslyExceptWhenSuppressed() {
        let gate = SnapshotGate()
        let monitor = DisplayMonitor(debounce: window, clock: TestClock(), snapshotGate: gate)

        monitor.beginSelfChange()
        XCTAssertFalse(monitor.receive(makeEvent(3, .movedFlag)))
        monitor.endSelfChange()
        XCTAssertFalse(monitor.receive(makeEvent(9, .addFlag, vendor: 0)))
        XCTAssertEqual(gate.status, SnapshotGate.Status(isOpen: true, epoch: 0, reason: nil))

        XCTAssertTrue(monitor.receive(makeEvent(3, .movedFlag)))
        XCTAssertEqual(gate.status, SnapshotGate.Status(isOpen: false, epoch: 1, reason: .displayChangeInProgress))
        XCTAssertTrue(monitor.receive(.screenParametersChanged()))
        XCTAssertEqual(gate.epoch, 2)
    }
}
