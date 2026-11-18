import XCTest
@testable import RoboboroKit

/// The two suspected bugs from docs/TEST-AUDIT-2026-11-18.md, section 4, items 2 and 3.
/// Trackers of their own, so `shared` is never touched.
final class AuditP0Tests: XCTestCase {
    private var storage: RoboboroMemoryStorage!
    private var transport: FakeTransport!

    override func setUp() {
        super.setUp()
        storage = RoboboroMemoryStorage()
        transport = FakeTransport()
    }

    private func config() -> RoboboroConfig {
        RoboboroConfig(
            siteId: "site_test",
            apiBase: "https://example.invalid/api/v1/roboboro",
            organisationSlug: "principia-one",
            environment: "test",
            flushInterval: 60,
            captureCrashes: false,
            sendsSessionStart: false,
            observesAppLifecycle: false
        )
    }

    private func sent(_ message: String) throws -> Int {
        try transport.batches().flatMap(\.batch).filter { $0.message == message }.count
    }

    /// Gap 2: `destroy()` while the post is in flight. The server accepts the batch, so the next start must not
    /// send it again.
    func testDestroyDuringFlightDoesNotResendAcknowledgedBatch() async throws {
        let first = RoboboroTracker()
        _ = await first.start(config: config(), storage: storage, transport: transport)
        first.captureMessage("once")
        transport.onSend = { [first] in first.destroy() }
        _ = await first.flush()
        XCTAssertEqual(try sent("once"), 1)

        transport.onSend = nil
        let second = RoboboroTracker()
        _ = await second.start(config: config(), storage: storage, transport: transport)
        _ = await second.flush()
        XCTAssertEqual(try sent("once"), 1, "the batch the server accepted was sent again after the next start")
        second.destroy()
    }

    /// Gap 3: with 100 events in flight, an event captured during the post must not vanish without a trace.
    func testAnEventCapturedWhileAHundredAreInFlightIsNotLost() async throws {
        let tracker = RoboboroTracker()
        _ = await tracker.start(config: config(), storage: storage, transport: transport)
        for index in 0..<100 { tracker.captureMessage("m\(index)") }
        // Only during the first chunk's post, while all 100 are in flight.
        let once = OnceFlag()
        transport.onSend = { [tracker] in if once.take() { tracker.captureMessage("late") } }
        let first = await tracker.flush()
        transport.onSend = nil
        let second = await tracker.flush()
        let lateSent = try sent("late")
        let accounted = lateSent + tracker.pendingCount + first.dropped + second.dropped
        XCTAssertGreaterThan(accounted, 0, "an event captured at the cap was neither sent, kept, nor counted as dropped")
        tracker.destroy()
    }

    /// Gap 3, eviction order and accounting: 150 events with the server down keep the newest 100 and count 50.
    func testAtTheCapTheOldestMakeRoomAndAreCounted() async throws {
        transport.status = 502
        let tracker = RoboboroTracker()
        _ = await tracker.start(config: config(), storage: storage, transport: transport)
        for index in 0..<150 { tracker.captureMessage("m\(index)") }
        XCTAssertEqual(tracker.pendingCount, 100)
        XCTAssertEqual(tracker.totals.dropped, 50)
        transport.status = 202
        // Past the backoff the failed flush would set; none has run yet, so this sends.
        _ = await tracker.flush()
        let messages = try transport.batches().flatMap(\.batch).compactMap(\.message)
        XCTAssertEqual(messages.first, "m50", "the oldest were the ones pushed out")
        XCTAssertEqual(messages.last, "m149")
        tracker.destroy()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
