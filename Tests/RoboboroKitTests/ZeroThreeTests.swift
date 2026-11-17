import XCTest
@testable import RoboboroKit

/// 0.3.0: what a flush reports, the test-result source, and trackers of your own.
final class ZeroThreeTests: XCTestCase {
    private var storage: RoboboroMemoryStorage!
    private var transport: FakeTransport!

    override func setUp() {
        super.setUp()
        RoboboroTracker.shared.resetForTests()
        storage = RoboboroMemoryStorage()
        transport = FakeTransport()
    }

    override func tearDown() {
        RoboboroTracker.shared.resetForTests()
        super.tearDown()
    }

    private func config(session: Bool = true) -> RoboboroConfig {
        RoboboroConfig(
            siteId: "site_test",
            apiBase: "https://example.invalid/api/v1/roboboro",
            organisationSlug: "principia-one",
            environment: "test",
            flushInterval: 60,
            captureCrashes: false,
            sendsSessionStart: session,
            observesAppLifecycle: false
        )
    }

    func testAFlushSaysWhatItSent() async throws {
        let started = await RoboboroTracker.shared.start(config: config(), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        tracker.captureMessage("one")
        tracker.captureMessage("two")
        let result = await tracker.flush()
        XCTAssertEqual(result, RoboboroFlushResult(sent: 3, dropped: 0, pending: 0, failure: nil), "Session start and two messages")
        let empty = await tracker.flush()
        XCTAssertEqual(empty, .nothing)
    }

    func testAFailedSendKeepsTheEventsAndSaysWhy() async throws {
        transport.status = 502
        let started = await RoboboroTracker.shared.start(config: config(session: false), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        tracker.captureMessage("kept")
        let result = await tracker.flush()
        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(result.pending, 1)
        XCTAssertEqual(result.failure, "http 502")
        XCTAssertEqual(tracker.pendingCount, 1)
    }

    func testARefusedChunkIsDroppedAndCounted() async throws {
        transport.status = 400
        let started = await RoboboroTracker.shared.start(config: config(session: false), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        tracker.captureMessage("never")
        let result = await tracker.flush()
        XCTAssertEqual(result.dropped, 1)
        XCTAssertEqual(result.pending, 0)
        XCTAssertEqual(result.failure, "http 400")
    }

    func testMoreThanFiftyEventsGoInChunksTheServerAccepts() async throws {
        let started = await RoboboroTracker.shared.start(config: config(session: false), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        for index in 0..<70 { tracker.captureMessage("m\(index)") }
        let result = await tracker.flush()
        XCTAssertEqual(result.sent, 70)
        XCTAssertEqual(try transport.batches().map(\.batch.count), [50, 20])
    }

    func testATestResultCarriesItsSourceAndRetries() async throws {
        let started = await RoboboroTracker.shared.start(config: config(session: false), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        tracker.captureTestResult(RoboboroTestResultInput(
            testName: "iOS › Home › Opens",
            status: .PASSED,
            durationMs: 1200,
            runId: "run-1",
            flaky: true,
            attempts: 2,
            data: ["suite": .string("Home")]
        ))
        tracker.captureMessage("app telemetry")
        await tracker.flush()
        let events = try transport.batches().flatMap(\.batch)
        let result = try XCTUnwrap(events.first { $0.type == .testResult })
        XCTAssertEqual(result.source, "xctest")
        XCTAssertEqual(result.data?["flaky"], .bool(true))
        XCTAssertEqual(result.data?["attempts"], .number(2))
        XCTAssertEqual(result.data?["suite"], .string("Home"))
        XCTAssertNil(events.first { $0.type == .message }?.source, "App telemetry keeps the server's default")
        let raw = try XCTUnwrap(String(data: try XCTUnwrap(transport.calls.first).body, encoding: .utf8))
        XCTAssertTrue(raw.contains(#""source":"xctest""#))
    }

    func testNoSessionEventWhenAsked() async throws {
        let started = await RoboboroTracker.shared.start(config: config(session: false), storage: storage, transport: transport)
        let tracker = try XCTUnwrap(started)
        let result = await tracker.flush()
        XCTAssertEqual(result, .nothing)
        XCTAssertNil(storage.get(RoboboroCore.visitorKey), "No session, no visitor id")
    }

    func testATrackerOfYourOwnNeverMixesWithShared() async throws {
        let appTransport = FakeTransport()
        _ = await RoboboroTracker.shared.start(config: config(session: false), storage: RoboboroMemoryStorage(), transport: appTransport)
        let own = RoboboroTracker()
        _ = await own.start(config: config(session: false), storage: storage, transport: transport)
        own.captureMessage("runner")
        RoboboroTracker.shared.captureMessage("app")
        await own.flush()
        await RoboboroTracker.shared.flush()
        XCTAssertEqual(try transport.batches().flatMap(\.batch).compactMap(\.message), ["runner"])
        XCTAssertEqual(try appTransport.batches().flatMap(\.batch).compactMap(\.message), ["app"])
        own.destroy()
    }

    func testStartDoesNotNeedTheMainThread() {
        // An XCTest observer blocks the main thread while it waits for start. Start must still finish.
        let done = expectation(description: "started")
        let storage = self.storage!
        let transport = self.transport!
        let config = self.config(session: true)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await RoboboroTracker.shared.start(config: config, storage: storage, transport: transport)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 3), .success)
        done.fulfill()
        wait(for: [done], timeout: 0)
    }

    func testDeviceInfoIsReadable() {
        XCTAssertFalse(RoboboroDevice.systemVersion.isEmpty)
        XCTAssertFalse(RoboboroDevice.model.isEmpty)
        XCTAssertFalse(RoboboroDevice.osName.isEmpty)
    }
}
