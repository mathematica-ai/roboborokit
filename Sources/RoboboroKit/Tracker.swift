import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Native iOS port of `p1-roboboro-tracker/native`.
///
/// ```swift
/// let tracker = await RoboboroTracker.shared.start(config: .init(
///     siteId: "p1-314-ios",
///     apiBase: "https://www.principia1.com/api/v1/roboboro",
///     organisationSlug: "principia-one"
/// ))
/// tracker?.trackScreen("Ask")
/// tracker?.captureException(error)
/// ```
public final class RoboboroTracker: @unchecked Sendable {
    public static let shared = RoboboroTracker()

    /// Longest wait between retries after consecutive failures.
    static let maxBackoff: TimeInterval = 300
    /// Delay before the queue is written to storage after a push.
    static let persistDelay: TimeInterval = 0.5

    private let lock = NSLock()
    private var storage: RoboboroStoring = RoboboroUserDefaultsStorage()
    private var transport: RoboboroTransporting = RoboboroURLSessionTransport()
    private var config: RoboboroConfig?
    private var active = false
    private var destroyed = false
    private var optedOut = false

    /// Unsent events not yet taken by a flush.
    private var queue: [RoboboroEvent] = []
    /// Events taken by the running flush and not yet acknowledged.
    private var inFlight: [RoboboroEvent] = []
    private var breadcrumbs: [RoboboroBreadcrumb] = []
    private var user: RoboboroUser?
    private var screen: String?
    private var flushTimer: Timer?
    private var flushTask: Task<RoboboroFlushResult, Never>?
    private var persistScheduled = false
    private var consecutiveFailures = 0
    private var sentTotal = 0
    private var droppedTotal = 0
    private var lastFailure: String?
    private var nextAttemptAt: Date?
    private var deviceOS: String = "ios"
    private var systemVersion: String?

    /// Clock, swappable in tests.
    var now: @Sendable () -> Date = { Date() }

    private let persistQueue = DispatchQueue(label: "roboboro.persist")

    /// A tracker of your own, apart from `shared`. A test runner uses one so its results never mix with the
    /// app's events, even when tests run inside the app. Crash capture stays with `shared`.
    public init() {}

    // MARK: Lifecycle

    /// Start (or return) the shared tracker. Returns `nil` when siteId / apiBase
    /// is missing, or when consent / opt-out rejects.
    ///
    /// Events left unsent by an earlier launch (or an uncaught exception) are
    /// loaded from storage and sent with the next flush.
    @discardableResult
    public func start(
        config: RoboboroConfig,
        storage customStorage: RoboboroStoring? = nil,
        transport customTransport: RoboboroTransporting? = nil
    ) async -> RoboboroTracker? {
        if isRunnable { return self }

        let siteId = config.siteId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiBase = config.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !siteId.isEmpty, !apiBase.isEmpty else { return nil }

        // Read without the main actor: a test observer calls `start` while the main thread waits for it.
        let version = RoboboroDevice.systemVersion
        let os = RoboboroDevice.osName

        enum Outcome { case alreadyRunning, rejected, started }
        let outcome: Outcome = withLock {
            if active && !destroyed && !optedOut { return .alreadyRunning }
            if let customStorage { storage = customStorage }
            if let customTransport { transport = customTransport }

            var resolved = config
            resolved.siteId = siteId
            resolved.apiBase = apiBase
            self.config = resolved

            optedOut = storage.get(RoboboroCore.optOutKey) == "1"
            let signals = RoboboroPrivacySignals(gpc: false, dnt: false, optedOut: optedOut)
            guard RoboboroConsent.granted(signals, hasConsent: config.hasConsent) else {
                return .rejected
            }

            destroyed = false
            active = true
            queue = loadPending()
            inFlight = []
            breadcrumbs = []
            user = nil
            screen = nil
            consecutiveFailures = 0
            nextAttemptAt = nil
            deviceOS = os
            systemVersion = version
            return .started
        }
        switch outcome {
        case .alreadyRunning: return self
        case .rejected: return nil
        case .started: break
        }

        // The uncaught-exception handler records on `shared`, so only `shared` installs it.
        if config.captureCrashes && self === RoboboroTracker.shared {
            RoboboroCrashCapture.install()
        }

        if config.sendsSessionStart {
            let visitor = withLock { ensureVisitorLocked() }
            push(type: .session, message: "session_start", extra: [
                "os": .string(os),
                "system_version": .string(version),
                "storage_persistent": .bool(withLock { storage.isPersistent }),
                "visitor_id": .string(visitor),
            ])
        }

        startTimer()
        if config.observesAppLifecycle {
            observeAppLifecycle()
        }
        return self
    }

    /// Stops tracking and drops the in-memory queue. Events already written
    /// to storage stay there and are sent after the next `start`.
    public func destroy() {
        withLock {
            destroyed = true
            active = false
            queue.removeAll()
            inFlight.removeAll()
        }
        stopTimer()
#if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.removeObserver(self)
#endif
    }

    func resetForTests() {
        destroy()
        persistQueue.sync {}
        withLock {
            storage = RoboboroMemoryStorage()
            transport = RoboboroURLSessionTransport()
            config = nil
            optedOut = false
            sentTotal = 0
            droppedTotal = 0
            lastFailure = nil
            user = nil
            breadcrumbs = []
            screen = nil
            flushTask = nil
            persistScheduled = false
            consecutiveFailures = 0
            nextAttemptAt = nil
        }
        now = { Date() }
    }

    /// Stops tracking, drops queued and stored events, and remembers the
    /// choice across launches.
    public func optOut() {
        withLock {
            storage.set(RoboboroCore.optOutKey, "1")
            storage.remove(RoboboroCore.pendingBufferKey)
            optedOut = true
            active = false
            queue.removeAll()
            inFlight.removeAll()
        }
        stopTimer()
    }

    /// Clears a stored opt-out. Tracking does not resume by itself: call
    /// `start(config:)` again to become active.
    public func optIn() {
        withLock {
            storage.remove(RoboboroCore.optOutKey)
            optedOut = false
        }
    }

    // MARK: Tracking API

    public func captureException(_ error: Error, extra: [String: Any]? = nil) {
        let message = RoboboroErrorFields.message(from: error)
        var data = extra.map { $0.mapValues { RoboboroJSON.from($0) } } ?? [:]
        data["os"] = .string(withLock { deviceOS })
        push(
            type: .exception,
            message: message,
            level: .error,
            error: message,
            trace: RoboboroErrorFields.trace(from: error),
            testName: message,
            status: .FAILED,
            fingerprint: RoboboroIDs.fingerprint(RoboboroErrorFields.fingerprintKey(from: error)),
            extra: data
        )
    }

    /// No-op: Core Web Vitals are browser measurements.
    public func captureWebVital() {}

    public func captureMessage(_ message: String, level: RoboboroLevel = .info) {
        push(type: .message, message: message, level: level, extra: nil)
    }

    public func addBreadcrumb(category: String, message: String, data: [String: Any]? = nil) {
        let crumb = RoboboroBreadcrumb(
            ts: nowMs(),
            category: category,
            message: message,
            data: data.map { $0.mapValues { RoboboroJSON.from($0) } }
        )
        withLock {
            guard active && !destroyed && !optedOut else { return }
            breadcrumbs.append(crumb)
            if breadcrumbs.count > 50 {
                breadcrumbs = Array(breadcrumbs.suffix(50))
            }
        }
    }

    public func identify(userId: String, traits: RoboboroUser? = nil) {
        withLock {
            user = RoboboroUser(id: userId, email: traits?.email, name: traits?.name)
        }
    }

    /// One test's outcome. The fingerprint is the test name, so a test keeps one row across runs.
    public func captureTestResult(_ result: RoboboroTestResultInput) {
        var data = result.data ?? [:]
        if result.flaky { data["flaky"] = .bool(true) }
        if let attempts = result.attempts { data["attempts"] = .number(Double(attempts)) }
        push(
            type: .testResult,
            message: result.testName,
            error: result.error,
            trace: result.trace,
            testName: result.testName,
            status: result.status,
            durationMs: result.durationMs,
            fingerprint: RoboboroIDs.fingerprint(result.testName),
            extra: data.isEmpty ? nil : data,
            runId: result.runId,
            videoUrl: result.videoUrl,
            source: result.source
        )
    }

    /// Sets the current screen and adds a `navigation` breadcrumb. Sends no
    /// event of its own: the screen rides along on the next event.
    public func trackScreen(_ name: String) {
        guard isRunnable else { return }
        withLock { screen = name }
        addBreadcrumb(category: "navigation", message: name)
    }

    // MARK: Crash capture

    /// Records an uncaught exception as a `.fatal` exception event and writes
    /// the queue to storage before returning, so it is sent on next launch.
    /// Called from the uncaught-exception handler; never blocks for long.
    func recordUncaughtException(_ exception: NSException) {
        let name = exception.name.rawValue
        let reason = exception.reason ?? ""
        let message = reason.isEmpty ? name : "\(name): \(reason)"
        let trace = exception.callStackSymbols.joined(separator: "\n")
        let key = name + "#" + RoboboroErrorFields.stripVolatile(reason)

        // The crash may have happened while this thread held the lock, or
        // another thread may hold it forever. Wait briefly, then give up.
        guard lock.lock(before: Date().addingTimeInterval(0.5)) else { return }
        defer { lock.unlock() }
        guard active && !destroyed && !optedOut, let cfg = config else { return }
        let event = makeEvent(
            cfg: cfg,
            type: .exception,
            message: message,
            level: .fatal,
            error: message,
            trace: trace.isEmpty ? nil : trace,
            testName: message,
            status: .FAILED,
            durationMs: nil,
            fingerprint: RoboboroIDs.fingerprint(key),
            extra: [
                "os": .string(deviceOS),
                "crash": .bool(true),
                "exception_name": .string(name),
            ],
            runId: nil,
            videoUrl: nil
        )
        appendLocked(event)
        writePendingLocked()
    }

    // MARK: Flush

    /// Sends what is queued, in chunks of at most 50 (the server's limit). Concurrent callers share one send
    /// and one result. A failed chunk stops the flush, stays queued, and waits out a growing backoff.
    @discardableResult
    public func flush() async -> RoboboroFlushResult {
        let task: Task<RoboboroFlushResult, Never> = withLock {
            if let existing = flushTask { return existing }
            let created = Task { [weak self] () -> RoboboroFlushResult in
                guard let self else { return .nothing }
                let result = await self.flushOnce()
                self.withLock {
                    self.sentTotal += result.sent
                    self.droppedTotal += result.dropped
                    self.lastFailure = result.failure
                }
                return result
            }
            flushTask = created
            return created
        }
        let result = await task.value
        withLock {
            if flushTask == task { flushTask = nil }
        }
        return result
    }

    private func flushOnce() async -> RoboboroFlushResult {
        guard let (snapshot, cfg) = takeBatch() else {
            return RoboboroFlushResult(pending: pendingCount)
        }
        guard let url = URL(string: RoboboroURL.ingest(cfg.apiBase)) else {
            requeueInFlight(failed: true)
            return RoboboroFlushResult(pending: pendingCount, failure: "bad apiBase")
        }

        var sent = 0
        var dropped = 0
        var failure: String?
        var remaining = snapshot
        while !remaining.isEmpty {
            let n = min(RoboboroCore.maxBatchSize, remaining.count)
            let chunk = Array(remaining.prefix(n))
            let payload = RoboboroBatch(
                siteId: cfg.siteId,
                organisationSlug: cfg.organisationSlug,
                runId: nil,
                platform: .native,
                environment: cfg.environment,
                release: cfg.release,
                batch: chunk
            )
            let body: Data
            do {
                body = try RoboboroPost.encode(batch: payload)
            } catch {
                // Cannot be encoded now, cannot be encoded later.
                remaining.removeFirst(n)
                acknowledge(chunk)
                dropped += n
                failure = "could not encode"
                continue
            }
            do {
                try await transport.send(url: url, apiKey: cfg.apiKey, body: body)
                remaining.removeFirst(n)
                acknowledge(chunk)
                resetBackoff()
                sent += n
            } catch {
                if RoboboroRetry.isPermanent(error) {
                    // 400 / 413: the server will never take this chunk.
                    remaining.removeFirst(n)
                    acknowledge(chunk)
                    dropped += n
                    failure = RoboboroRetry.describe(error)
                    continue
                }
                requeueInFlight(failed: true)
                return RoboboroFlushResult(sent: sent, dropped: dropped, pending: pendingCount, failure: RoboboroRetry.describe(error))
            }
        }
        return RoboboroFlushResult(sent: sent, dropped: dropped, pending: pendingCount, failure: failure)
    }

    /// Everything since `start`: events accepted and refused by every flush, the timer's included, what is
    /// still pending, and the latest flush's failure.
    public var totals: RoboboroFlushResult {
        withLock {
            RoboboroFlushResult(sent: sentTotal, dropped: droppedTotal, pending: queue.count + inFlight.count, failure: lastFailure)
        }
    }

    /// Events not yet accepted: queued and in flight.
    public var pendingCount: Int {
        withLock { queue.count + inFlight.count }
    }

    // MARK: Internals

    /// Sync lock helper so `async` methods never call `NSLock` directly
    /// (unavailable from async in the Swift 6 SDK).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Moves the queue into `inFlight`, unless a backoff is pending.
    private func takeBatch() -> ([RoboboroEvent], RoboboroConfig)? {
        withLock {
            guard let cfg = config, !optedOut else { return nil }
            if let next = nextAttemptAt, now() < next { return nil }
            guard !queue.isEmpty else { return nil }
            inFlight = queue
            queue = []
            // On disk before the post, so a kill mid-flight sends it next launch.
            writePendingLocked()
            return (inFlight, cfg)
        }
    }

    /// Removes sent (or permanently rejected) events and writes what is left.
    private func acknowledge(_ chunk: [RoboboroEvent]) {
        let ids = Set(chunk.map(\.eventId))
        withLock {
            inFlight.removeAll { ids.contains($0.eventId) }
            writePendingLocked()
        }
    }

    private func requeueInFlight(failed: Bool) {
        withLock {
            queue = inFlight + queue
            inFlight = []
            if queue.count > RoboboroCore.maxPending {
                queue = Array(queue.suffix(RoboboroCore.maxPending))
            }
            if failed {
                consecutiveFailures += 1
                let delay = min(
                    Self.maxBackoff,
                    RoboboroCore.defaultFlushInterval * pow(2, Double(consecutiveFailures - 1))
                )
                nextAttemptAt = now().addingTimeInterval(delay)
            }
            writePendingLocked()
        }
    }

    private func resetBackoff() {
        withLock {
            consecutiveFailures = 0
            nextAttemptAt = nil
        }
    }

    /// Seconds until the next flush may send, or `nil` when none is pending.
    var backoffRemaining: TimeInterval? {
        withLock {
            guard let next = nextAttemptAt else { return nil }
            return max(0, next.timeIntervalSince(now()))
        }
    }

    private var isRunnable: Bool {
        withLock { active && !destroyed && !optedOut }
    }

    /// Caller holds the lock. A stable id for this install. Not an account, and not an email.
    private func ensureVisitorLocked() -> String {
        if let existing = storage.get(RoboboroCore.visitorKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let created = RoboboroIDs.generateId(prefix: "rbv")
        storage.set(RoboboroCore.visitorKey, created)
        return created
    }

    private func nowMs() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1000)
    }

    private func push(
        type: RoboboroEventType,
        message: String? = nil,
        level: RoboboroLevel? = nil,
        error: String? = nil,
        trace: String? = nil,
        testName: String? = nil,
        status: RoboboroTestStatus? = nil,
        durationMs: Int? = nil,
        fingerprint: String? = nil,
        extra: [String: RoboboroJSON]? = nil,
        runId: String? = nil,
        videoUrl: String? = nil,
        source: String? = nil
    ) {
        let pushed: Bool = withLock {
            guard active && !destroyed && !optedOut, let cfg = config else { return false }
            let event = makeEvent(
                cfg: cfg,
                type: type,
                message: message,
                level: level,
                error: error,
                trace: trace,
                testName: testName,
                status: status,
                durationMs: durationMs,
                fingerprint: fingerprint,
                extra: extra,
                runId: runId,
                videoUrl: videoUrl,
                source: source
            )
            appendLocked(event)
            return true
        }
        if pushed { schedulePersist() }
    }

    /// Caller holds the lock.
    private func makeEvent(
        cfg: RoboboroConfig,
        type: RoboboroEventType,
        message: String?,
        level: RoboboroLevel?,
        error: String?,
        trace: String?,
        testName: String?,
        status: RoboboroTestStatus?,
        durationMs: Int?,
        fingerprint: String?,
        extra: [String: RoboboroJSON]?,
        runId: String?,
        videoUrl: String?,
        source: String? = nil
    ) -> RoboboroEvent {
        RoboboroEvent(
            eventId: RoboboroIDs.generateId(),
            type: type,
            ts: nowMs(),
            siteId: cfg.siteId,
            organisationSlug: cfg.organisationSlug,
            runId: runId,
            fingerprint: fingerprint,
            testName: testName,
            status: status,
            durationMs: durationMs,
            error: error,
            trace: trace,
            videoUrl: videoUrl,
            environment: cfg.environment,
            platform: .native,
            release: cfg.release,
            level: level,
            message: message,
            user: user,
            breadcrumbs: Array(breadcrumbs.suffix(20)),
            screen: screen,
            url: nil,
            pathname: nil,
            data: extra,
            source: source
        )
    }

    /// Caller holds the lock.
    private func appendLocked(_ event: RoboboroEvent) {
        queue.append(event)
        let room = max(0, RoboboroCore.maxPending - inFlight.count)
        if queue.count > room {
            queue = Array(queue.suffix(room))
        }
    }

    /// Debounced write of the unsent events, so a kill loses at most
    /// `persistDelay` of events.
    private func schedulePersist() {
        let shouldSchedule: Bool = withLock {
            if persistScheduled { return false }
            persistScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        persistQueue.asyncAfter(deadline: .now() + Self.persistDelay) { [weak self] in
            self?.persistNow()
        }
    }

    /// Writes the unsent events (in flight + queued) to storage now.
    func persistNow() {
        withLock {
            persistScheduled = false
            guard !destroyed else { return }
            writePendingLocked()
        }
    }

    /// Caller holds the lock. After `destroy` the stored events are left
    /// alone for the next `start`.
    private func writePendingLocked() {
        if destroyed && !optedOut { return }
        let unsent = inFlight + queue
        if optedOut || unsent.isEmpty {
            storage.remove(RoboboroCore.pendingBufferKey)
            return
        }
        let capped = Array(unsent.suffix(RoboboroCore.maxPending))
        if let data = try? JSONEncoder().encode(capped),
           let s = String(data: data, encoding: .utf8) {
            storage.set(RoboboroCore.pendingBufferKey, s)
        }
    }

    /// Caller holds the lock.
    private func loadPending() -> [RoboboroEvent] {
        guard let raw = storage.get(RoboboroCore.pendingBufferKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RoboboroEvent].self, from: data) else {
            return []
        }
        return Array(decoded.suffix(RoboboroCore.maxPending))
    }

    private func startTimer() {
        let interval = withLock { config?.flushInterval ?? RoboboroCore.defaultFlushInterval }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer?.invalidate()
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { await self?.flush() }
            }
        }
    }

    private func stopTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.flushTimer?.invalidate()
            self?.flushTimer = nil
        }
    }

    private func observeAppLifecycle() {
#if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
#endif
    }

#if canImport(UIKit) && !os(watchOS)
    /// Posted on the main thread. Asks for background time so the flush can
    /// finish, and ends it on completion or expiry.
    @MainActor @objc private func didEnterBackground() {
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.id = application.beginBackgroundTask(withName: "roboboro.flush") {
            box.end(application)
        }
        Task { [weak self] in
            await self?.flush()
            await MainActor.run { box.end(application) }
        }
    }

    @MainActor
    private final class BackgroundTaskBox {
        var id: UIBackgroundTaskIdentifier = .invalid

        func end(_ application: UIApplication) {
            let ending = id
            id = .invalid
            if ending != .invalid {
                application.endBackgroundTask(ending)
            }
        }
    }
#endif
}

/// Uncaught Objective-C exception capture. Installed once by `start` when
/// `captureCrashes` is on; chains to any handler installed before it.
///
/// Signals (SIGSEGV, SIGABRT from Swift traps) are not captured: a signal
/// handler may only call async-signal-safe functions, and encoding an event
/// is not one.
enum RoboboroCrashCapture {
    typealias Handler = @convention(c) (NSException) -> Void

    private static let lock = NSLock()
    private static var installed = false
    private static var _previous: Handler?

    /// The handler that was installed before ours (tests may replace it).
    static var previous: Handler? {
        get { lock.lock(); defer { lock.unlock() }; return _previous }
        set { lock.lock(); defer { lock.unlock() }; _previous = newValue }
    }

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        _previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(handler)
    }

    static let handler: Handler = { exception in
        RoboboroCrashCapture.handle(exception)
    }

    /// Records the exception on the shared tracker, then calls the previous handler.
    static func handle(_ exception: NSException) {
        RoboboroTracker.shared.recordUncaughtException(exception)
        previous?(exception)
    }
}

/// What the tracker says about the device, read off the main thread.
public enum RoboboroDevice {
    /// `27.3`.
    public static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// `iPhone18,2`. On a simulator, the simulated model.
    public static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// `ios`, `ipados`, `macos`, `tvos`, or `watchos`.
    public static var osName: String {
#if os(iOS)
        return model.hasPrefix("iPad") ? "ipados" : "ios"
#elseif os(macOS)
        return "macos"
#elseif os(tvOS)
        return "tvos"
#elseif os(watchOS)
        return "watchos"
#else
        return "unknown"
#endif
    }
}

@discardableResult
public func initRoboboroTracker(
    config: RoboboroConfig,
    storage: RoboboroStoring? = nil,
    transport: RoboboroTransporting? = nil
) async -> RoboboroTracker? {
    await RoboboroTracker.shared.start(config: config, storage: storage, transport: transport)
}
