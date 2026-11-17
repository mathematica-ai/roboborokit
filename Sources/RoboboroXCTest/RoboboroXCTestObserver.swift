import Foundation
import RoboboroKit
import XCTest

/// Sends every XCTest result to Roboboro, the way p1-website's Playwright reporter does for the web.
///
/// Make it the test bundle's principal class and nothing else is needed:
///
/// ```yaml
/// # XcodeGen
/// info:
///   properties:
///     NSPrincipalClass: RoboboroXCTest.RoboboroXCTestObserver
///     RoboboroAPIBase: https://www.principia1.com/api/v1/roboboro
///     RoboboroOrganisationSlug: principia-one
/// ```
///
/// It stays silent until the runner has a site id. xcodebuild hands the runner every variable prefixed
/// `TEST_RUNNER_`, without the prefix:
///
/// ```sh
/// TEST_RUNNER_ROBOBORO_SITE_ID=site_… xcodebuild test -scheme AppUITests …
/// ```
///
/// One row per test: its readable name, PASSED, FAILED or SKIPPED, the time it took, and the first failure with
/// where it happened. A test that failed and then passed on a retry is sent once, as PASSED and flaky.
/// Results use their own tracker, so they never mix with the app's events, and the source `xctest`, so
/// Roboboro keeps passes as well as failures. At the end it prints one line saying what was sent.
open class RoboboroXCTestObserver: NSObject, XCTestObservation, @unchecked Sendable {
    public let settings: RoboboroXCTestSettings?
    public let tracker: RoboboroTracker

    /// Tests swap the network out.
    var transport: RoboboroTransporting?

    private let lock = NSLock()
    private var startedAt: [String: Date] = [:]
    private var firstIssue: [String: XCTIssue] = [:]
    private var outcomes: [String: Outcome] = [:]
    private var order: [String] = []
    private var reporting = false
    private var captured = 0
    /// The line printed at the end of the run, kept for tests.
    private(set) var closingLine: String?

    struct Outcome {
        var suite: String
        var status: RoboboroTestStatus
        var durationMs: Int
        var error: String?
        var trace: String?
        var attempts: Int
        var everFailed: Bool
    }

    /// Reads the settings from the runner's environment and the test bundle's Info.plist, then registers.
    public override convenience init() {
        self.init(
            settings: RoboboroXCTestSettings.resolve(
                environment: ProcessInfo.processInfo.environment,
                info: Bundle(for: Self.self).infoDictionary ?? [:]
            ),
            tracker: RoboboroTracker()
        )
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    /// For tests of the observer: nothing is registered.
    public init(settings: RoboboroXCTestSettings?, tracker: RoboboroTracker) {
        self.settings = settings
        self.tracker = tracker
        super.init()
    }

    // MARK: XCTestObservation

    open func testBundleWillStart(_ testBundle: Bundle) {
        guard let settings else {
            Self.log("Roboboro: off. Set ROBOBORO_SITE_ID (TEST_RUNNER_ROBOBORO_SITE_ID for xcodebuild) and an API base to report this run.")
            return
        }
        let config = settings.trackerConfig
        let tracker = self.tracker
        let transport = self.transport
        let started = Self.waiting(seconds: 10) {
            await tracker.start(config: config, storage: RoboboroMemoryStorage(), transport: transport) != nil
        }
        lock.withLock { reporting = started == true }
        if started != true {
            Self.log("Roboboro: could not start. Results from this run are not sent.")
        }
    }

    open func testCaseWillStart(_ testCase: XCTestCase) {
        lock.withLock {
            startedAt[testCase.name] = Date()
            firstIssue[testCase.name] = nil
        }
    }

    open func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        lock.withLock {
            if firstIssue[testCase.name] == nil { firstIssue[testCase.name] = issue }
        }
    }

    open func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let run = testCase.testRun else { return }
        let status: RoboboroTestStatus = run.hasBeenSkipped ? .SKIPPED : (run.hasSucceeded ? .PASSED : .FAILED)
        lock.withLock {
            let began = startedAt.removeValue(forKey: testCase.name)
            let issue = firstIssue.removeValue(forKey: testCase.name)
            let duration = began.map { Int(Date().timeIntervalSince($0) * 1000) } ?? Int(run.totalDuration * 1000)
            let suite = Self.parts(of: testCase.name).suite
            var outcome = outcomes[testCase.name] ?? Outcome(
                suite: suite, status: status, durationMs: 0, error: nil, trace: nil, attempts: 0, everFailed: false
            )
            if outcomes[testCase.name] == nil { order.append(testCase.name) }
            outcome.attempts += 1
            outcome.status = status
            outcome.durationMs = duration
            outcome.everFailed = outcome.everFailed || status == .FAILED
            outcome.error = status == .FAILED ? (issue?.compactDescription ?? "Failed") : nil
            outcome.trace = status == .FAILED ? issue.map(Self.location) : nil
            outcomes[testCase.name] = outcome
        }
    }

    /// A class's tests, retries included, have all run by the end of its suite. Send them then, so a runner that
    /// dies later still reported what finished.
    open func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        guard testSuite.tests.contains(where: { $0 is XCTestCase }) else { return }
        send(names: Set(testSuite.tests.map(\.name)))
        guard lock.withLock({ reporting }) else { return }
        let tracker = self.tracker
        Task.detached { await tracker.flush() }
    }

    open func testBundleDidFinish(_ testBundle: Bundle) {
        send(names: nil)
        guard lock.withLock({ reporting }), let settings else { return }
        let tracker = self.tracker
        // The totals, not the last drain: earlier classes may have gone out on their own flush or the timer.
        let result = Self.waiting(seconds: 30) { () -> RoboboroFlushResult in
            _ = await Self.drain(tracker)
            return tracker.totals
        }
        let line = Self.summary(result: result, captured: lock.withLock { captured }, settings: settings)
        lock.withLock { closingLine = line }
        Self.log(line)
    }

    // MARK: Sending

    private func send(names: Set<String>?) {
        let ready: [(String, Outcome)] = lock.withLock {
            let picked = order.filter { names?.contains($0) ?? true }
            order.removeAll { picked.contains($0) }
            let list = picked.compactMap { name in outcomes.removeValue(forKey: name).map { (name, $0) } }
            if reporting { captured += list.count }
            return reporting ? list : []
        }
        guard let settings else { return }
        for (name, outcome) in ready {
            tracker.captureTestResult(RoboboroTestResultInput(
                testName: Self.readableName(name, prefix: settings.namePrefix),
                status: outcome.status,
                durationMs: outcome.durationMs,
                error: outcome.error,
                trace: outcome.trace,
                runId: settings.runId,
                source: RoboboroSource.xctest,
                flaky: outcome.everFailed && outcome.status == .PASSED,
                attempts: outcome.attempts,
                data: [
                    "suite": .string(outcome.suite),
                    "device": .string(RoboboroDevice.model),
                    "os_version": .string(RoboboroDevice.systemVersion),
                ]
            ))
        }
    }

    /// Flushes until nothing is left or a send fails. One flush may stop early while a backoff is pending.
    static func drain(_ tracker: RoboboroTracker) async -> RoboboroFlushResult {
        var total = RoboboroFlushResult()
        for _ in 0..<5 {
            let step = await tracker.flush()
            total.sent += step.sent
            total.dropped += step.dropped
            total.pending = step.pending
            total.failure = step.failure ?? total.failure
            if step.pending == 0 || step.failure != nil { break }
        }
        return total
    }

    // MARK: Pieces

    /// `-[HomeJourneyTests testScrubbingShowsThatDay]` reads as `iOS › HomeJourneyTests › Scrubbing shows that day`.
    public static func readableName(_ raw: String, prefix: String = "iOS") -> String {
        let (suite, method) = parts(of: raw)
        guard !method.isEmpty else { return "\(prefix) › \(raw)" }
        var name = method
        if name.hasPrefix("test") { name.removeFirst(4) }
        let letters = Array(name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces))
        var words = ""
        for (index, character) in letters.enumerated() {
            let previous = index > 0 ? letters[index - 1] : nil
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            // A capital starts a word after a lowercase letter (OpensThe), or ends an acronym before one (URLSheet).
            let startsWord = character.isUppercase && previous.map { prior in
                prior.isLowercase || prior.isNumber || (prior.isUppercase && (next?.isLowercase ?? false))
            } ?? false
            if startsWord { words.append(" ") }
            words.append(words.isEmpty ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        let sentence = words.split(separator: " ").joined(separator: " ")
        return "\(prefix) › \(suite) › \(sentence)"
    }

    static func parts(of raw: String) -> (suite: String, method: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
        let pieces = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return (trimmed, "") }
        let suite = pieces[0].split(separator: ".").last.map(String.init) ?? pieces[0]
        return (suite, pieces[1])
    }

    static func summary(result: RoboboroFlushResult?, captured: Int, settings: RoboboroXCTestSettings) -> String {
        let host = URL(string: settings.apiBase)?.host ?? settings.apiBase
        guard let result else {
            return "Roboboro: \(captured) results not confirmed. The send to \(host) did not finish in time."
        }
        var line = "Roboboro: \(result.sent) of \(captured) results sent to \(host), run \(settings.runId), \(settings.environment)."
        if result.dropped > 0 { line += " \(result.dropped) refused." }
        if result.pending > 0 { line += " \(result.pending) not sent." }
        if let failure = result.failure { line += " Last failure: \(failure)." }
        return line
    }

    private static func location(_ issue: XCTIssue) -> String {
        let detail = issue.detailedDescription ?? issue.compactDescription
        guard let location = issue.sourceCodeContext.location else { return detail }
        return "\(location.fileURL.lastPathComponent):\(location.lineNumber)\n\(detail)"
    }

    private static func log(_ line: String) {
        print(line)
    }

    /// XCTest calls observers synchronously on the main thread. This waits for async work off it, with a ceiling
    /// so a dead network never hangs a run. Nil when the ceiling was reached.
    static func waiting<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await work()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Where the results go and how they are labelled. From the runner's environment first, then the test bundle's
/// Info.plist. The API key is read from the environment only, never from a plist that ships in a bundle.
public struct RoboboroXCTestSettings: Sendable, Equatable {
    public var siteId: String
    public var apiBase: String
    public var apiKey: String?
    public var organisationSlug: String?
    public var environment: String
    public var runId: String
    public var release: String?
    public var namePrefix: String

    public init(
        siteId: String,
        apiBase: String,
        apiKey: String? = nil,
        organisationSlug: String? = nil,
        environment: String = "local",
        runId: String = UUID().uuidString,
        release: String? = nil,
        namePrefix: String = "iOS"
    ) {
        self.siteId = siteId
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.organisationSlug = organisationSlug
        self.environment = environment
        self.runId = runId
        self.release = release
        self.namePrefix = namePrefix
    }

    /// Nil when there is no site id or no API base: the run is not reported.
    ///
    /// | Setting | Environment | Info.plist |
    /// |---|---|---|
    /// | site id | `ROBOBORO_SITE_ID` | `RoboboroSiteID` |
    /// | API base | `ROBOBORO_API_BASE` | `RoboboroAPIBase` |
    /// | API key | `ROBOBORO_API_KEY` | (never) |
    /// | organisation | `ROBOBORO_ORGANISATION_SLUG` | `RoboboroOrganisationSlug` |
    /// | environment | `ROBOBORO_ENVIRONMENT`, else `ci` when `CI` is set, else `local` | |
    /// | run id | `ROBOBORO_RUN_ID`, `GITHUB_RUN_ID`, or a new UUID | |
    /// | release | `ROBOBORO_RELEASE`, else the bundle's version and build | |
    /// | name prefix | `ROBOBORO_NAME_PREFIX` | `RoboboroNamePrefix`, else `iOS` |
    public static func resolve(environment env: [String: String], info: [String: Any]) -> RoboboroXCTestSettings? {
        func value(_ key: String, plist: String? = nil) -> String? {
            let raw = env[key] ?? plist.flatMap { info[$0] as? String }
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let siteId = value("ROBOBORO_SITE_ID", plist: "RoboboroSiteID"),
              let apiBase = value("ROBOBORO_API_BASE", plist: "RoboboroAPIBase") else { return nil }
        let release: String? = value("ROBOBORO_RELEASE") ?? {
            guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
            if let build = info["CFBundleVersion"] as? String, !build.isEmpty { return "\(version)+\(build)" }
            return version
        }()
        return RoboboroXCTestSettings(
            siteId: siteId,
            apiBase: apiBase,
            apiKey: value("ROBOBORO_API_KEY"),
            organisationSlug: value("ROBOBORO_ORGANISATION_SLUG", plist: "RoboboroOrganisationSlug"),
            environment: value("ROBOBORO_ENVIRONMENT") ?? (value("CI") == nil ? "local" : "ci"),
            runId: value("ROBOBORO_RUN_ID") ?? value("GITHUB_RUN_ID") ?? UUID().uuidString,
            release: release,
            namePrefix: value("ROBOBORO_NAME_PREFIX", plist: "RoboboroNamePrefix") ?? "iOS"
        )
    }

    /// A tracker of its own: no session event, no crash capture, no app lifecycle, and a slow timer, since the
    /// observer flushes at the end of each class and of the run.
    public var trackerConfig: RoboboroConfig {
        RoboboroConfig(
            siteId: siteId,
            apiBase: apiBase,
            apiKey: apiKey,
            organisationSlug: organisationSlug,
            environment: environment,
            release: release,
            flushInterval: 30,
            captureCrashes: false,
            sendsSessionStart: false,
            observesAppLifecycle: false
        )
    }
}
