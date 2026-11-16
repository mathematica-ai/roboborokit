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

    private let lock = NSLock()
    private var storage: RoboboroStoring = RoboboroUserDefaultsStorage()
    private var transport: RoboboroTransporting = RoboboroURLSessionTransport()
    private var config: RoboboroConfig?
    private var active = false
    private var destroyed = false
    private var optedOut = false

    private var queue: [RoboboroEvent] = []
    private var breadcrumbs: [RoboboroBreadcrumb] = []
    private var user: RoboboroUser?
    private var screen: String?
    private var flushTimer: Timer?
    private var flushTask: Task<Void, Never>?
    private var deviceOS: String = "ios"
    private var systemVersion: String?

    private init() {}

    // MARK: Lifecycle

    /// Start (or return) the shared tracker. Returns `nil` when siteId / apiBase
    /// is missing, or when consent / opt-out rejects.
    @discardableResult
    public func start(
        config: RoboboroConfig,
        storage customStorage: RoboboroStoring? = nil,
        transport customTransport: RoboboroTransporting? = nil
    ) async -> RoboboroTracker? {
        let siteId = config.siteId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiBase = config.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !siteId.isEmpty, !apiBase.isEmpty else { return nil }
        if withLock({ active && !destroyed && !optedOut }) { return self }

#if canImport(UIKit)
        let version = await MainActor.run { UIDevice.current.systemVersion }
        let os = await MainActor.run { UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios" }
#else
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let os = "macos"
#endif

        let began: Bool = withLock {
            if active && !destroyed && !optedOut { return false }
            if let customStorage { storage = customStorage }
            if let customTransport { transport = customTransport }
            var resolved = config
            resolved.siteId = siteId
            resolved.apiBase = apiBase
            self.config = resolved
            optedOut = storage.get(RoboboroCore.optOutKey) == "1"
            let signals = RoboboroPrivacySignals(gpc: false, dnt: false, optedOut: optedOut)
            guard RoboboroConsent.granted(signals, hasConsent: config.hasConsent) else {
                return false
            }
            destroyed = false
            active = true
            queue = []
            breadcrumbs = []
            user = nil
            screen = nil
            deviceOS = os
            systemVersion = version
            return true
        }
        guard began else {
            return withLock { active && !destroyed && !optedOut } ? self : nil
        }

        let visitor = ensureVisitor()
        push(type: .session, message: "session_start", extra: [
            "os": .string(deviceOS),
            "system_version": systemVersion.map { .string($0) } ?? .null,
            "storage_persistent": .bool(storage.isPersistent),
            "visitor_id": .string(visitor),
        ])

        startTimer()
        observeAppLifecycle()
        return self
    }

    public func destroy() {
        invalidateTimer()
        withLock {
            destroyed = true
            active = false
            queue.removeAll()
        }
#if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
#endif
    }

    func resetForTests() {
        destroy()
        lock.lock()
        storage = RoboboroMemoryStorage()
        transport = RoboboroURLSessionTransport()
        config = nil
        optedOut = false
        user = nil
        breadcrumbs = []
        screen = nil
        flushTask = nil
        lock.unlock()
    }

    public func optOut() {
        storage.set(RoboboroCore.optOutKey, "1")
        storage.remove(RoboboroCore.pendingBufferKey)
        withLock {
            optedOut = true
            queue.removeAll()
        }
        invalidateTimer()
    }

    // MARK: Tracking API

    public func captureException(_ error: Error, extra: [String: Any]? = nil) {
        let message = RoboboroErrorFields.message(from: error)
        var data = extra.map { $0.mapValues { RoboboroJSON.from($0) } } ?? [:]
        data["os"] = .string(deviceOS)
        push(
            type: .exception,
            message: message,
            level: .error,
            error: message,
            trace: RoboboroErrorFields.trace(from: error),
            testName: message,
            status: .FAILED,
            fingerprint: RoboboroIDs.fingerprint(message),
            extra: data
        )
    }

    /// No-op: Core Web Vitals are browser measurements.
    public func captureWebVital() {}

    public func captureMessage(_ message: String, level: RoboboroLevel = .info) {
        push(type: .message, message: message, level: level, extra: nil)
    }

    public func addBreadcrumb(category: String, message: String, data: [String: Any]? = nil) {
        guard isRunnable else { return }
        let crumb = RoboboroBreadcrumb(
            ts: nowMs(),
            category: category,
            message: message,
            data: data.map { $0.mapValues { RoboboroJSON.from($0) } }
        )
        lock.lock()
        breadcrumbs.append(crumb)
        if breadcrumbs.count > 50 {
            breadcrumbs = Array(breadcrumbs.suffix(50))
        }
        lock.unlock()
    }

    public func identify(userId: String, traits: RoboboroUser? = nil) {
        lock.lock()
        user = RoboboroUser(id: userId, email: traits?.email, name: traits?.name)
        lock.unlock()
    }

    public func captureTestResult(_ result: RoboboroTestResultInput) {
        push(
            type: .testResult,
            message: result.testName,
            error: result.error,
            trace: result.trace,
            testName: result.testName,
            status: result.status,
            durationMs: result.durationMs,
            fingerprint: RoboboroIDs.fingerprint(result.testName),
            extra: nil,
            runId: result.runId,
            videoUrl: result.videoUrl
        )
    }

    public func trackScreen(_ name: String) {
        guard isRunnable else { return }
        lock.lock()
        screen = name
        lock.unlock()
        addBreadcrumb(category: "navigation", message: name)
        push(type: .session, message: "screen", extra: nil)
    }

    // MARK: Flush

    public func flush() async {
        if let existing = currentFlushTask() {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.flushOnce()
        }
        setFlushTask(task)
        await task.value
        setFlushTask(nil)
    }

    private func flushOnce() async {
        let prepared: (events: [RoboboroEvent], config: RoboboroConfig?) = drainQueue()
        let snapshot = prepared.events
        let cfg = prepared.config
        guard let cfg, !snapshot.isEmpty else { return }
        // Opt-out wins over a batch that was already taken off the queue.
        guard !isOptedOut else { return }
        guard let url = URL(string: RoboboroURL.ingest(cfg.apiBase)) else {
            requeue(snapshot)
            return
        }

        var remaining = snapshot
        while !remaining.isEmpty {
            guard !isOptedOut else { return }
            let n = min(RoboboroCore.maxBatchSize, remaining.count)
            let chunk = Array(remaining.prefix(n))
            // Written before the request, so a kill mid-flight retries next launch.
            savePending(remaining)
            let payload = RoboboroBatch(
                siteId: cfg.siteId,
                organisationSlug: cfg.organisationSlug,
                runId: nil,
                platform: .native,
                environment: cfg.environment,
                release: cfg.release,
                batch: chunk
            )
            do {
                let body = try RoboboroPost.encode(batch: payload)
                try await transport.send(url: url, apiKey: cfg.apiKey, body: body)
                remaining.removeFirst(n)
                if remaining.isEmpty {
                    clearPending()
                } else {
                    savePending(remaining)
                }
            } catch {
                if !isOptedOut { requeue(remaining) }
                return
            }
        }
    }

    // MARK: Internals

    /// Sync lock helper so `async` methods never call `NSLock` directly
    /// (unavailable from async in the Swift 6 SDK).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func currentFlushTask() -> Task<Void, Never>? {
        withLock { flushTask }
    }

    private func setFlushTask(_ task: Task<Void, Never>?) {
        withLock { flushTask = task }
    }

    private func drainQueue() -> ([RoboboroEvent], RoboboroConfig?) {
        withLock {
            let pending = loadPending()
            if !pending.isEmpty {
                clearPending()
                queue = pending + queue
                if queue.count > RoboboroCore.maxPending {
                    queue = Array(queue.suffix(RoboboroCore.maxPending))
                }
            }
            let snapshot = queue
            queue = []
            return (snapshot, config)
        }
    }

    private var isRunnable: Bool {
        withLock { active && !destroyed && !optedOut }
    }

    private var isOptedOut: Bool {
        withLock { optedOut }
    }

    /// Stable device id for this install. Not an account, and not an email.
    private func ensureVisitor() -> String {
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
        Int64(Date().timeIntervalSince1970 * 1000)
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
        videoUrl: String? = nil
    ) {
        let event: RoboboroEvent? = withLock {
        guard active && !destroyed && !optedOut, let cfg = config else { return nil }
        let event = RoboboroEvent(
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
            data: extra
        )
        queue.append(event)
        if queue.count > RoboboroCore.maxPending {
            queue = Array(queue.suffix(RoboboroCore.maxPending))
        }
        return event
        }
        guard event != nil else { return }
    }

    private func requeue(_ events: [RoboboroEvent]) {
        withLock {
            queue = (events + queue)
            if queue.count > RoboboroCore.maxPending {
                queue = Array(queue.suffix(RoboboroCore.maxPending))
            }
            savePending(queue)
        }
    }

    private func loadPending() -> [RoboboroEvent] {
        guard let raw = storage.get(RoboboroCore.pendingBufferKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RoboboroEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePending(_ events: [RoboboroEvent]) {
        if let data = try? JSONEncoder().encode(events),
           let s = String(data: data, encoding: .utf8) {
            storage.set(RoboboroCore.pendingBufferKey, s)
        }
    }

    private func clearPending() {
        storage.remove(RoboboroCore.pendingBufferKey)
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

    private func invalidateTimer() {
        let work = {
            self.flushTimer?.invalidate()
            self.flushTimer = nil
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func observeAppLifecycle() {
#if canImport(UIKit)
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

#if canImport(UIKit)
    @objc private func didEnterBackground() {
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.id = application.beginBackgroundTask(withName: "roboboro.flush") {
            let ending = box.id
            box.id = .invalid
            if ending != .invalid {
                application.endBackgroundTask(ending)
            }
        }
        Task {
            await flush()
            await MainActor.run {
                let ending = box.id
                box.id = .invalid
                if ending != .invalid {
                    application.endBackgroundTask(ending)
                }
            }
        }
    }

    private final class BackgroundTaskBox: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
    }
#endif
}

@discardableResult
public func initRoboboroTracker(
    config: RoboboroConfig,
    storage: RoboboroStoring? = nil,
    transport: RoboboroTransporting? = nil
) async -> RoboboroTracker? {
    await RoboboroTracker.shared.start(config: config, storage: storage, transport: transport)
}
