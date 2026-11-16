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
    var status: Int = 202
    var error: Error?
    var onSend: (@Sendable () -> Void)?

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func send(url: URL, apiKey: String?, body: Data) async throws {
        let recorded = record(url: url, apiKey: apiKey, body: body)
        if let error = recorded.error { throw error }
        guard (200..<300).contains(recorded.status) else {
            throw RoboboroTransportError.http(recorded.status)
        }
    }

    private func record(url: URL, apiKey: String?, body: Data) -> (status: Int, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(url: url, apiKey: apiKey, body: body))
        let hook = onSend
        lock.unlock()
        hook?()
        lock.lock()
        return (status, error)
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
        XCTAssertEqual(exception.fingerprint, RoboboroIDs.fingerprint("brain load failed"))
        XCTAssertEqual(exception.data?["phase"], .string("load_brain"))
    }

    func testTrackScreenAddsNavigationBreadcrumb() async throws {
        let tracker = await startTracker()
        tracker?.trackScreen("Ask")
        await tracker?.flush()

        let body = try JSONDecoder().decode(RoboboroBatch.self, from: XCTUnwrap(transport.calls.first).body)
        let screenEvent = try XCTUnwrap(body.batch.first { $0.message == "screen" })
        XCTAssertEqual(screenEvent.type, .session)
        XCTAssertEqual(screenEvent.screen, "Ask")
        XCTAssertEqual(screenEvent.breadcrumbs?.last?.category, "navigation")
        XCTAssertEqual(screenEvent.breadcrumbs?.last?.message, "Ask")
    }

    func testHttpErrorRequeuesThenRetries() async throws {
        let tracker = await startTracker()
        tracker?.captureMessage("hello")
        transport.status = 500
        await tracker?.flush()
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertFalse((storage.get(RoboboroCore.pendingBufferKey) ?? "").isEmpty)

        transport.status = 202
        await tracker?.flush()
        XCTAssertEqual(transport.calls.count, 2)
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

    func testFlushKeepsTheBatchUntilThePostSucceeds() async throws {
        let tracker = await startTracker()
        tracker?.captureMessage("kept")
        transport.onSend = { [storage] in
            let raw = storage?.get(RoboboroCore.pendingBufferKey) ?? ""
            XCTAssertTrue(raw.contains("kept"))
        }
        await tracker?.flush()
        XCTAssertNil(storage.get(RoboboroCore.pendingBufferKey))
    }

    func testSessionStoresAVisitorId() async throws {
        let tracker = await startTracker()
        await tracker?.flush()
        let body = try JSONDecoder().decode(RoboboroBatch.self, from: XCTUnwrap(transport.calls.first).body)
        let session = try XCTUnwrap(body.batch.first { $0.message == "session_start" })
        let stored = try XCTUnwrap(storage.get(RoboboroCore.visitorKey))
        XCTAssertEqual(session.data?["visitor_id"], .string(stored))
        XCTAssertTrue(stored.hasPrefix("rbv_"))
    }

    func testRedirectStaysOnHttpsAndTheSameHost() {
        let bff = URL(string: "https://www.principia1.com/api/v1/roboboro/ingest")
        XCTAssertTrue(RoboboroRedirect.follows(
            from: bff,
            to: URL(string: "https://www.principia1.com/api/v1/roboboro/ingest/")
        ))
        XCTAssertFalse(RoboboroRedirect.follows(
            from: bff,
            to: URL(string: "http://www.principia1.com/api/v1/roboboro/ingest")
        ))
        XCTAssertFalse(RoboboroRedirect.follows(
            from: bff,
            to: URL(string: "https://evil.example/ingest")
        ))
        XCTAssertFalse(RoboboroRedirect.follows(from: bff, to: nil))
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
