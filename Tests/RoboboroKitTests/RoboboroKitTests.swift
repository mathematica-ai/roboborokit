import XCTest
@testable import RoboboroKit

final class FakeTransport: RoboboroTransporting, @unchecked Sendable {
    struct Call {
        var url: URL
        var apiKey: String?
        var body: Data
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    var status: Int = 202
    var error: Error?
    var delayNs: UInt64 = 0

    var maxInFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return _maxInFlight
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func send(url: URL, apiKey: String?, body: Data) async throws {
        let recorded = record(url: url, apiKey: apiKey, body: body)
        if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
        finish()
        if let error = recorded.error { throw error }
        guard (200..<300).contains(recorded.status) else {
            throw RoboboroTransportError.http(recorded.status)
        }
    }

    private func record(url: URL, apiKey: String?, body: Data) -> (status: Int, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(url: url, apiKey: apiKey, body: body))
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
        return (status, error)
    }

    private func finish() {
        lock.lock(); defer { lock.unlock() }
        _inFlight -= 1
    }

    func batches() throws -> [RoboboroBatch] {
        try calls.map { try JSONDecoder().decode(RoboboroBatch.self, from: $0.body) }
    }
}

enum SampleError: Error {
    case notFound
    case failed(String)
}

final class ChainedHandlerFlag: @unchecked Sendable {
    static let shared = ChainedHandlerFlag()
    private let lock = NSLock()
    private var _name: String?
    var name: String? {
        get { lock.lock(); defer { lock.unlock() }; return _name }
        set { lock.lock(); defer { lock.unlock() }; _name = newValue }
    }
}

final class RoboboroKitTests: XCTestCase {
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

    func testGenerateIdPrefix() {
        let id = RoboboroIDs.generateId()
        XCTAssertTrue(id.hasPrefix("rb_"))
        XCTAssertEqual(id.count, 3 + 24) // rb_ + 12 bytes hex
    }

    func testFingerprintMatchesJS() {
        XCTAssertEqual(RoboboroIDs.fingerprint("Chaos › Forecast"), "6d41f6dc829c1cd4")
        XCTAssertEqual(
            RoboboroIDs.fingerprint("Chaos › Forecast"),
            RoboboroIDs.fingerprint("  chaos › forecast ")
        )
    }

    func testIngestUrlAppendsOnce() {
        XCTAssertEqual(RoboboroURL.ingest("/api/v1/roboboro"), "/api/v1/roboboro/ingest")
        XCTAssertEqual(
            RoboboroURL.ingest("https://x/api/v1/roboboro/ingest"),
            "https://x/api/v1/roboboro/ingest"
        )
    }

    func testConsentHonoursOptOut() {
        XCTAssertFalse(RoboboroConsent.granted(
            RoboboroPrivacySignals(gpc: false, dnt: false, optedOut: true),
            hasConsent: { _ in true }
        ))
        XCTAssertTrue(RoboboroConsent.granted(
            RoboboroPrivacySignals(gpc: false, dnt: false, optedOut: false),
            hasConsent: { _ in true }
        ))
        XCTAssertFalse(RoboboroConsent.granted(
            RoboboroPrivacySignals(gpc: true, dnt: false, optedOut: false),
            hasConsent: { _ in true }
        ))
        XCTAssertTrue(RoboboroConsent.granted(
            RoboboroPrivacySignals(gpc: true, dnt: false, optedOut: false),
            hasConsent: { _ in true },
            overrideBrowserSignals: true
        ))
    }

    func testInitRejectsEmptySiteId() async {
        let t = await initRoboboroTracker(
            config: RoboboroConfig(siteId: "  ", apiBase: "https://example.invalid/api/v1/roboboro"),
            storage: storage,
            transport: transport
        )
        XCTAssertNil(t)
    }

    func testInitRejectsEmptyApiBase() async {
        let t = await initRoboboroTracker(
            config: RoboboroConfig(siteId: "site", apiBase: ""),
            storage: storage,
            transport: transport
        )
        XCTAssertNil(t)
    }

    func testCaptureExceptionSerializesAndFlushes() async throws {
        let tracker = await startTracker()
        XCTAssertNotNil(tracker)
        tracker?.captureException(
            NSError(domain: "P1314", code: 43, userInfo: [NSLocalizedDescriptionKey: "brain load failed"]),
            extra: ["phase": "load_brain"]
        )
        await tracker?.flush()

        XCTAssertEqual(transport.calls.count, 1)
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.url.absoluteString, "https://example.invalid/api/v1/roboboro/ingest")
        XCTAssertEqual(call.apiKey, "sk_p1_test")

        let body = try JSONDecoder().decode(RoboboroBatch.self, from: call.body)
        XCTAssertEqual(body.siteId, "site_test")
        XCTAssertEqual(body.platform, .native)
        XCTAssertEqual(body.organisationSlug, "principia-one")

        let types = body.batch.map(\.type)
        XCTAssertTrue(types.contains(.session))
        let exception = try XCTUnwrap(body.batch.first { $0.type == .exception })
        XCTAssertEqual(exception.message, "brain load failed")
        XCTAssertEqual(exception.error, "brain load failed")
        XCTAssertEqual(exception.testName, "brain load failed")
        XCTAssertEqual(exception.status, .FAILED)
        XCTAssertEqual(exception.level, .error)
        XCTAssertEqual(exception.fingerprint, RoboboroIDs.fingerprint("P1314#43"))
        XCTAssertEqual(exception.data?["phase"], .string("load_brain"))
    }

    func testTrackScreenAddsBreadcrumbWithoutEvent() async throws {
        let tracker = await startTracker()
        tracker?.trackScreen("Ask")
        tracker?.captureMessage("after screen")
        await tracker?.flush()

        let body = try XCTUnwrap(transport.batches().first)
        XCTAssertFalse(body.batch.contains { $0.message == "screen" })
        XCTAssertEqual(body.batch.map(\.message), ["session_start", "after screen"])
        let message = try XCTUnwrap(body.batch.last)
        XCTAssertEqual(message.screen, "Ask")
        XCTAssertEqual(message.breadcrumbs?.last?.category, "navigation")
        XCTAssertEqual(message.breadcrumbs?.last?.message, "Ask")
    }

    func testHttpErrorRequeuesThenRetries() async throws {
        let tracker = await startTracker()
        tracker?.captureMessage("hello")
        transport.status = 500
        await tracker?.flush()
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertFalse((storage.get(RoboboroCore.pendingBufferKey) ?? "").isEmpty)

        transport.status = 202
        advanceClock(tracker, by: 6)
        await tracker?.flush()
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertNil(storage.get(RoboboroCore.pendingBufferKey))
        let second = try JSONDecoder().decode(RoboboroBatch.self, from: XCTUnwrap(transport.calls.last).body)
        XCTAssertTrue(second.batch.contains { $0.message == "hello" })
    }

    func testOptOutDropsQueueAndPersists() async {
        let tracker = await startTracker()
        tracker?.captureMessage("before")
        tracker?.optOut()
        tracker?.captureMessage("after")
        await tracker?.flush()
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(storage.get(RoboboroCore.optOutKey), "1")

        RoboboroTracker.shared.resetForTests()
        let again = await initRoboboroTracker(
            config: RoboboroConfig(
                siteId: "site_test",
                apiBase: "https://example.invalid/api/v1/roboboro"
            ),
            storage: storage,
            transport: transport
        )
        XCTAssertNil(again)
    }

    func testConsentCallbackCanBlockInit() async {
        let blocked = await initRoboboroTracker(
            config: RoboboroConfig(
                siteId: "site_test",
                apiBase: "https://example.invalid/api/v1/roboboro",
                hasConsent: { _ in false }
            ),
            storage: storage,
            transport: transport
        )
        XCTAssertNil(blocked)
    }

    // MARK: 0.2.0 reliability

    func testCrashHandlerPersistsFatalEventAndChains() async throws {
        let trackerMaybe = await startTracker()
        let tracker = try XCTUnwrap(trackerMaybe)
        XCTAssertTrue(RoboboroCrashCapture.isInstalled)
        let original = RoboboroCrashCapture.previous
        defer { RoboboroCrashCapture.previous = original }
        ChainedHandlerFlag.shared.name = nil
        RoboboroCrashCapture.previous = { exception in
            ChainedHandlerFlag.shared.name = exception.name.rawValue
        }

        let exception = NSException(
            name: .invalidArgumentException,
            reason: "index 5 beyond bounds [0 .. 2]",
            userInfo: nil
        )
        RoboboroCrashCapture.handle(exception)

        XCTAssertEqual(ChainedHandlerFlag.shared.name, NSExceptionName.invalidArgumentException.rawValue)
        // Persisted synchronously, before the process would die.
        let raw = try XCTUnwrap(storage.get(RoboboroCore.pendingBufferKey))
        let stored = try JSONDecoder().decode([RoboboroEvent].self, from: Data(raw.utf8))
        let crash = try XCTUnwrap(stored.first { $0.type == .exception })
        XCTAssertEqual(crash.level, .fatal)
        XCTAssertEqual(crash.data?["crash"], .bool(true))
        XCTAssertTrue(crash.message?.contains("beyond bounds") ?? false)

        // Same bug with other indices groups together.
        let other = NSException(name: .invalidArgumentException, reason: "index 9 beyond bounds [0 .. 7]", userInfo: nil)
        tracker.recordUncaughtException(other)
        let raw2 = try XCTUnwrap(storage.get(RoboboroCore.pendingBufferKey))
        let crashes = try JSONDecoder().decode([RoboboroEvent].self, from: Data(raw2.utf8)).filter { $0.type == .exception }
        XCTAssertEqual(crashes.count, 2)
        XCTAssertEqual(crashes[0].fingerprint, crashes[1].fingerprint)

        // Next launch sends it.
        RoboboroTracker.shared.resetForTests()
        let relaunchedMaybe = await startTracker()
        let relaunched = try XCTUnwrap(relaunchedMaybe)
        await relaunched.flush()
        XCTAssertTrue(try transport.batches().flatMap(\.batch).contains { $0.level == .fatal })
    }

    func testCaptureCrashesFlagOff() async throws {
        let tracker = await initRoboboroTracker(
            config: RoboboroConfig(
                siteId: "site_test",
                apiBase: "https://example.invalid/api/v1/roboboro",
                flushInterval: 60,
                captureCrashes: false
            ),
            storage: storage,
            transport: transport
        )
        XCTAssertNotNil(tracker)
        XCTAssertFalse(RoboboroConfig(siteId: "s", apiBase: "b", captureCrashes: false).captureCrashes)
        XCTAssertTrue(RoboboroConfig(siteId: "s", apiBase: "b").captureCrashes)
    }

    func testQueueSurvivesNewTrackerInstance() async throws {
        let first = RoboboroTracker()
        _ = await first.start(config: config(), storage: storage, transport: transport)
        first.captureMessage("unsent")
        first.persistNow()
        XCTAssertTrue(transport.calls.isEmpty)

        // A new process: new instance, same storage.
        let second = RoboboroTracker()
        _ = await second.start(config: config(), storage: storage, transport: transport)
        await second.flush()
        let messages = try transport.batches().flatMap(\.batch).compactMap(\.message)
        XCTAssertTrue(messages.contains("unsent"))
        XCTAssertNil(storage.get(RoboboroCore.pendingBufferKey))
        first.destroy()
        second.destroy()
    }

    func testPushIsPersistedAfterDebounce() async throws {
        let tracker = await startTracker()
        tracker?.captureMessage("soon stored")
        try await Task.sleep(nanoseconds: UInt64((RoboboroTracker.persistDelay + 0.3) * 1_000_000_000))
        let raw = try XCTUnwrap(storage.get(RoboboroCore.pendingBufferKey))
        XCTAssertTrue(raw.contains("soon stored"))
    }

    func testFingerprintIgnoresLocalizedDescription() {
        let english = NSError(domain: "P1314", code: 7, userInfo: [NSLocalizedDescriptionKey: "Network lost"])
        let portuguese = NSError(domain: "P1314", code: 7, userInfo: [NSLocalizedDescriptionKey: "Rede perdida"])
        XCTAssertEqual(RoboboroErrorFields.fingerprintKey(from: english), "P1314#7")
        XCTAssertEqual(
            RoboboroErrorFields.fingerprintKey(from: english),
            RoboboroErrorFields.fingerprintKey(from: portuguese)
        )
        XCTAssertEqual(
            RoboboroErrorFields.fingerprintKey(from: SampleError.failed("um")),
            RoboboroErrorFields.fingerprintKey(from: SampleError.failed("dois"))
        )
        XCTAssertNotEqual(
            RoboboroErrorFields.fingerprintKey(from: SampleError.notFound),
            RoboboroErrorFields.fingerprintKey(from: SampleError.failed("x"))
        )
        XCTAssertTrue(RoboboroErrorFields.fingerprintKey(from: SampleError.notFound).hasSuffix("SampleError.notFound"))
    }

    func testCaptureExceptionSameFingerprintAcrossLanguages() async throws {
        let tracker = await startTracker()
        tracker?.captureException(NSError(domain: "P1314", code: 7, userInfo: [NSLocalizedDescriptionKey: "Network lost"]))
        tracker?.captureException(NSError(domain: "P1314", code: 7, userInfo: [NSLocalizedDescriptionKey: "Rede perdida"]))
        await tracker?.flush()
        let exceptions = try transport.batches().flatMap(\.batch).filter { $0.type == .exception }
        XCTAssertEqual(exceptions.count, 2)
        XCTAssertEqual(exceptions[0].fingerprint, exceptions[1].fingerprint)
        XCTAssertEqual(exceptions.map(\.message), ["Network lost", "Rede perdida"])
    }

    func testConcurrentFlushSendsOnce() async throws {
        let trackerMaybe = await startTracker()
        let tracker = try XCTUnwrap(trackerMaybe)
        tracker.captureMessage("one")
        transport.delayNs = 200_000_000
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await tracker.flush() }
            }
        }
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.maxInFlight, 1)
    }

    func testOptInClearsOptOutAndNeedsStart() async throws {
        let trackerMaybe = await startTracker()
        let tracker = try XCTUnwrap(trackerMaybe)
        tracker.optOut()
        XCTAssertEqual(storage.get(RoboboroCore.optOutKey), "1")

        tracker.optIn()
        XCTAssertNil(storage.get(RoboboroCore.optOutKey))
        tracker.captureMessage("before start")
        await tracker.flush()
        XCTAssertTrue(transport.calls.isEmpty)

        let restarted = await startTracker()
        XCTAssertNotNil(restarted)
        restarted?.captureMessage("after start")
        await restarted?.flush()
        let messages = try transport.batches().flatMap(\.batch).compactMap(\.message)
        XCTAssertTrue(messages.contains("after start"))
        XCTAssertFalse(messages.contains("before start"))
    }

    func testBadRequestDropsChunk() async throws {
        for status in [400, 413] {
            RoboboroTracker.shared.resetForTests()
            storage = RoboboroMemoryStorage()
            transport = FakeTransport()
            let tracker = await startTracker()
            tracker?.captureMessage("rejected")
            transport.status = status
            await tracker?.flush()
            XCTAssertEqual(transport.calls.count, 1)
            XCTAssertNil(storage.get(RoboboroCore.pendingBufferKey), "status \(status)")
            XCTAssertNil(tracker?.backoffRemaining)

            transport.status = 202
            await tracker?.flush()
            XCTAssertEqual(transport.calls.count, 1, "dropped chunk must not be resent")
        }
    }

    func testServiceUnavailableRequeuesWithBackoff() async throws {
        let trackerMaybe = await startTracker()
        let tracker = try XCTUnwrap(trackerMaybe)
        tracker.captureMessage("retry me")
        transport.status = 503
        await tracker.flush()
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertFalse((storage.get(RoboboroCore.pendingBufferKey) ?? "").isEmpty)
        XCTAssertEqual(tracker.backoffRemaining ?? -1, 5, accuracy: 0.5)

        // Inside the backoff window nothing is sent.
        await tracker.flush()
        XCTAssertEqual(transport.calls.count, 1)

        // Second failure doubles the wait.
        advanceClock(tracker, by: 6)
        await tracker.flush()
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(tracker.backoffRemaining ?? -1, 10, accuracy: 0.5)

        // Cap at five minutes.
        for _ in 0..<10 {
            advanceClock(tracker, by: 400)
            await tracker.flush()
        }
        XCTAssertEqual(tracker.backoffRemaining ?? -1, RoboboroTracker.maxBackoff, accuracy: 0.5)

        transport.status = 202
        advanceClock(tracker, by: 400)
        await tracker.flush()
        XCTAssertNil(tracker.backoffRemaining)
        XCTAssertTrue(try XCTUnwrap(transport.batches().last).batch.contains { $0.message == "retry me" })
        XCTAssertNil(storage.get(RoboboroCore.pendingBufferKey))
    }

    func testRetryClassification() {
        XCTAssertTrue(RoboboroRetry.isPermanent(RoboboroTransportError.http(400)))
        XCTAssertTrue(RoboboroRetry.isPermanent(RoboboroTransportError.http(413)))
        XCTAssertFalse(RoboboroRetry.isPermanent(RoboboroTransportError.http(429)))
        XCTAssertFalse(RoboboroRetry.isPermanent(RoboboroTransportError.http(502)))
        XCTAssertFalse(RoboboroRetry.isPermanent(URLError(.notConnectedToInternet)))
    }

    private func advanceClock(_ tracker: RoboboroTracker?, by seconds: TimeInterval) {
        guard let tracker else { return }
        let current = tracker.now()
        tracker.now = { current.addingTimeInterval(seconds) }
    }

    private func config() -> RoboboroConfig {
        RoboboroConfig(
            siteId: "site_test",
            apiBase: "https://example.invalid/api/v1/roboboro",
            apiKey: "sk_p1_test",
            organisationSlug: "principia-one",
            environment: "test",
            release: "0.2.0",
            flushInterval: 60
        )
    }

    private func startTracker() async -> RoboboroTracker? {
        await initRoboboroTracker(
            config: RoboboroConfig(
                siteId: "site_test",
                apiBase: "https://example.invalid/api/v1/roboboro",
                apiKey: "sk_p1_test",
                organisationSlug: "principia-one",
                environment: "test",
                release: "0.1.0",
                flushInterval: 60
            ),
            storage: storage,
            transport: transport
        )
    }
}
