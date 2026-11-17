import RoboboroKit
import XCTest
@testable import RoboboroXCTest

final class RecordingTransport: RoboboroTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    var status = 202

    func send(url: URL, apiKey: String?, body: Data) async throws {
        let status: Int = lock.withLock {
            bodies.append(body)
            return self.status
        }
        guard (200..<300).contains(status) else { throw RoboboroTransportError.http(status) }
    }

    func events() throws -> [RoboboroEvent] {
        try lock.withLock { bodies }.flatMap { try JSONDecoder().decode(RoboboroBatch.self, from: $0).batch }
    }
}

/// Stand-ins the observer watches. They run inside these tests, not as tests of their own.
final class SampleJourneys: XCTestCase {
    static var failNext = false

    override class var defaultTestSuite: XCTestSuite { XCTestSuite(name: "SampleJourneys (not run directly)") }

    func testPasses() {}

    func testFailsOnce() {
        if Self.failNext {
            Self.failNext = false
            XCTFail("Wobbly")
        }
    }

    func testFails() {
        XCTFail("Broken for good")
    }

    func testSkips() throws {
        throw XCTSkip("Not on this device")
    }
}

final class RoboboroXCTestObserverTests: XCTestCase {
    private let settings = RoboboroXCTestSettings(
        siteId: "site_0123456789abcdef",
        apiBase: "https://example.test/api/v1/roboboro",
        organisationSlug: "principia-one",
        environment: "ci",
        runId: "run-42",
        release: "1.2+3"
    )

    private func observer(_ transport: RecordingTransport) -> RoboboroXCTestObserver {
        let observer = RoboboroXCTestObserver(settings: settings, tracker: RoboboroTracker())
        observer.transport = transport
        return observer
    }

    /// Runs a sample test with the observer watching, as XCTest would.
    private func run(_ selector: Selector, under observer: RoboboroXCTestObserver, issue: String? = nil) {
        let test = SampleJourneys(selector: selector)
        observer.testCaseWillStart(test)
        test.run()
        if let issue {
            observer.testCase(test, didRecord: XCTIssue(type: .assertionFailure, compactDescription: issue))
        }
        observer.testCaseDidFinish(test)
    }

    // MARK: Names

    func testNamesReadLikeSentences() {
        XCTAssertEqual(
            RoboboroXCTestObserver.readableName("-[HomeJourneyTests testScrubbingTheChartReturnsToTodayOnLift]"),
            "iOS › HomeJourneyTests › Scrubbing the chart returns to today on lift"
        )
        XCTAssertEqual(
            RoboboroXCTestObserver.readableName("-[iMoneyUITests.BuyJourneyTests testBuyFiveDollars]", prefix: "iMoney"),
            "iMoney › BuyJourneyTests › Buy five dollars"
        )
        XCTAssertEqual(
            RoboboroXCTestObserver.readableName("-[Suite test_snake_case]"),
            "iOS › Suite › Snake case"
        )
        XCTAssertEqual(RoboboroXCTestObserver.readableName("odd"), "iOS › odd")
    }

    func testAnAcronymStaysOneWord() {
        XCTAssertEqual(
            RoboboroXCTestObserver.readableName("-[Suite testOpensTheURLSheet]"),
            "iOS › Suite › Opens the url sheet"
        )
    }

    // MARK: Settings

    func testSettingsComeFromTheEnvironmentThenThePlist() throws {
        let resolved = try XCTUnwrap(RoboboroXCTestSettings.resolve(
            environment: ["ROBOBORO_SITE_ID": " site_abc ", "GITHUB_RUN_ID": "77", "CI": "true"],
            info: [
                "RoboboroAPIBase": "https://www.principia1.com/api/v1/roboboro",
                "RoboboroOrganisationSlug": "principia-one",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "13",
            ]
        ))
        XCTAssertEqual(resolved.siteId, "site_abc")
        XCTAssertEqual(resolved.apiBase, "https://www.principia1.com/api/v1/roboboro")
        XCTAssertEqual(resolved.organisationSlug, "principia-one")
        XCTAssertEqual(resolved.runId, "77")
        XCTAssertEqual(resolved.environment, "ci")
        XCTAssertEqual(resolved.release, "0.1.0+13")
        XCTAssertNil(resolved.apiKey)
    }

    func testTheEnvironmentWinsOverThePlist() throws {
        let resolved = try XCTUnwrap(RoboboroXCTestSettings.resolve(
            environment: ["ROBOBORO_SITE_ID": "site_env", "ROBOBORO_API_BASE": "https://env.test", "ROBOBORO_ENVIRONMENT": "monitor"],
            info: ["RoboboroSiteID": "site_plist", "RoboboroAPIBase": "https://plist.test"]
        ))
        XCTAssertEqual(resolved.siteId, "site_env")
        XCTAssertEqual(resolved.apiBase, "https://env.test")
        XCTAssertEqual(resolved.environment, "monitor")
    }

    func testNoSiteIdOrNoBaseMeansOff() {
        XCTAssertNil(RoboboroXCTestSettings.resolve(environment: [:], info: ["RoboboroAPIBase": "https://x.test"]))
        XCTAssertNil(RoboboroXCTestSettings.resolve(environment: ["ROBOBORO_SITE_ID": "site_x"], info: [:]))
        XCTAssertNil(RoboboroXCTestSettings.resolve(environment: ["ROBOBORO_SITE_ID": "  "], info: ["RoboboroAPIBase": "https://x.test"]))
    }

    func testTheKeyIsNeverReadFromThePlist() throws {
        let resolved = try XCTUnwrap(RoboboroXCTestSettings.resolve(
            environment: ["ROBOBORO_SITE_ID": "site_x"],
            info: ["RoboboroAPIBase": "https://x.test", "ROBOBORO_API_KEY": "sk_p1_leak", "RoboboroAPIKey": "sk_p1_leak"]
        ))
        XCTAssertNil(resolved.apiKey)
    }

    func testTheTrackerIsQuietAboutItself() {
        let config = settings.trackerConfig
        XCTAssertFalse(config.sendsSessionStart)
        XCTAssertFalse(config.captureCrashes)
        XCTAssertFalse(config.observesAppLifecycle)
    }

    // MARK: Results

    func testEachOutcomeIsSentOnceWithItsStatusAndSource() throws {
        let transport = RecordingTransport()
        let observer = observer(transport)
        observer.testBundleWillStart(Bundle.main)
        run(#selector(SampleJourneys.testPasses), under: observer)
        run(#selector(SampleJourneys.testFails), under: observer, issue: "Broken for good")
        run(#selector(SampleJourneys.testSkips), under: observer)
        observer.testBundleDidFinish(Bundle.main)

        let events = try transport.events()
        XCTAssertEqual(events.count, 3, "No session event: a test runner is not a person")
        XCTAssertTrue(events.allSatisfy { $0.type == .testResult && $0.source == RoboboroSource.xctest })
        XCTAssertTrue(events.allSatisfy { $0.runId == "run-42" && $0.environment == "ci" && $0.release == "1.2+3" })
        let byName = Dictionary(uniqueKeysWithValues: events.map { ($0.testName ?? "", $0) })
        XCTAssertEqual(byName["iOS › SampleJourneys › Passes"]?.status, .PASSED)
        XCTAssertNil(byName["iOS › SampleJourneys › Passes"]?.error)
        XCTAssertEqual(byName["iOS › SampleJourneys › Fails"]?.status, .FAILED)
        XCTAssertEqual(byName["iOS › SampleJourneys › Fails"]?.error, "Broken for good")
        XCTAssertEqual(byName["iOS › SampleJourneys › Skips"]?.status, .SKIPPED)
        XCTAssertEqual(byName["iOS › SampleJourneys › Passes"]?.data?["suite"], .string("SampleJourneys"))
        XCTAssertEqual(byName["iOS › SampleJourneys › Passes"]?.fingerprint, RoboboroIDs.fingerprint("iOS › SampleJourneys › Passes"))
    }

    func testAFailureThenAPassIsOneFlakyPass() throws {
        let transport = RecordingTransport()
        let observer = observer(transport)
        observer.testBundleWillStart(Bundle.main)
        SampleJourneys.failNext = true
        run(#selector(SampleJourneys.testFailsOnce), under: observer, issue: "Wobbly")
        run(#selector(SampleJourneys.testFailsOnce), under: observer)
        observer.testBundleDidFinish(Bundle.main)

        let events = try transport.events()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.status, .PASSED)
        XCTAssertEqual(event.data?["flaky"], .bool(true))
        XCTAssertEqual(event.data?["attempts"], .number(2))
        XCTAssertNil(event.error)
    }

    func testOffSendsNothing() throws {
        let transport = RecordingTransport()
        let observer = RoboboroXCTestObserver(settings: nil, tracker: RoboboroTracker())
        observer.transport = transport
        observer.testBundleWillStart(Bundle.main)
        run(#selector(SampleJourneys.testPasses), under: observer)
        observer.testBundleDidFinish(Bundle.main)
        XCTAssertTrue(try transport.events().isEmpty)
    }

    // MARK: The closing line

    func testTheSummarySaysWhatHappened() {
        XCTAssertEqual(
            RoboboroXCTestObserver.summary(result: RoboboroFlushResult(sent: 8), captured: 8, settings: settings),
            "Roboboro: 8 of 8 results sent to example.test, run run-42, ci."
        )
        XCTAssertEqual(
            RoboboroXCTestObserver.summary(result: RoboboroFlushResult(sent: 0, pending: 8, failure: "http 502"), captured: 8, settings: settings),
            "Roboboro: 0 of 8 results sent to example.test, run run-42, ci. 8 not sent. Last failure: http 502."
        )
        XCTAssertEqual(
            RoboboroXCTestObserver.summary(result: nil, captured: 3, settings: settings),
            "Roboboro: 3 results not confirmed. The send to example.test did not finish in time."
        )
    }

    func testARefusedSendIsReported() throws {
        let transport = RecordingTransport()
        transport.status = 502
        let observer = observer(transport)
        observer.testBundleWillStart(Bundle.main)
        run(#selector(SampleJourneys.testPasses), under: observer)
        let tracker = observer.tracker
        observer.testSuiteDidFinish(XCTestSuite(name: "unused"))
        observer.testBundleDidFinish(Bundle.main)
        let result = RoboboroXCTestObserver.waiting(seconds: 5) { await tracker.flush() }
        XCTAssertEqual(result?.pending, 1, "A 502 keeps the result for a retry")
    }
}
