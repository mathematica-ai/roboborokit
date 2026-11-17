import Foundation

public struct RoboboroUser: Codable, Sendable, Equatable {
    public var id: String?
    public var email: String?
    public var name: String?

    public init(id: String? = nil, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

public struct RoboboroBreadcrumb: Codable, Sendable, Equatable {
    public var ts: Int64
    public var category: String
    public var message: String
    public var data: [String: RoboboroJSON]?

    public init(ts: Int64, category: String, message: String, data: [String: RoboboroJSON]? = nil) {
        self.ts = ts
        self.category = category
        self.message = message
        self.data = data
    }
}

public struct RoboboroTestResultInput: Sendable {
    public var testName: String
    public var status: RoboboroTestStatus
    public var durationMs: Int?
    public var error: String?
    public var trace: String?
    public var videoUrl: String?
    public var runId: String?

    public init(
        testName: String,
        status: RoboboroTestStatus,
        durationMs: Int? = nil,
        error: String? = nil,
        trace: String? = nil,
        videoUrl: String? = nil,
        runId: String? = nil
    ) {
        self.testName = testName
        self.status = status
        self.durationMs = durationMs
        self.error = error
        self.trace = trace
        self.videoUrl = videoUrl
        self.runId = runId
    }
}

public struct RoboboroEvent: Codable, Sendable, Equatable {
    public var eventId: String
    public var type: RoboboroEventType
    public var ts: Int64
    public var siteId: String
    public var organisationSlug: String?
    public var runId: String?
    public var fingerprint: String?
    public var testName: String?
    public var status: RoboboroTestStatus?
    public var durationMs: Int?
    public var error: String?
    public var trace: String?
    public var videoUrl: String?
    public var environment: String?
    public var platform: RoboboroPlatform
    public var release: String?
    public var level: RoboboroLevel?
    public var message: String?
    public var user: RoboboroUser?
    public var breadcrumbs: [RoboboroBreadcrumb]?
    public var screen: String?
    public var url: String?
    public var pathname: String?
    public var data: [String: RoboboroJSON]?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case type, ts
        case siteId = "site_id"
        case organisationSlug = "organisation_slug"
        case runId = "run_id"
        case fingerprint
        case testName = "test_name"
        case status
        case durationMs = "duration_ms"
        case error, trace
        case videoUrl = "video_url"
        case environment, platform, release, level, message, user, breadcrumbs, screen, url, pathname, data
    }
}

public struct RoboboroBatch: Codable, Sendable {
    public var siteId: String
    public var organisationSlug: String?
    public var runId: String?
    public var platform: RoboboroPlatform
    public var environment: String?
    public var release: String?
    public var batch: [RoboboroEvent]

    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case organisationSlug = "organisation_slug"
        case runId = "run_id"
        case platform, environment, release, batch
    }
}

public struct RoboboroConfig: Sendable {
    public var siteId: String
    /// Absolute ingest base, e.g. `https://www.principia1.com/api/v1/roboboro`
    /// (Next BFF) or `{P1_API_URL}/api/v1/roboboro` (sublime-go). Required —
    /// there is no silent production default.
    public var apiBase: String
    /// Organisation token (`sk_p1_…` / `P1_API_KEY`). Omit when `apiBase` is a
    /// BFF that attaches the key itself.
    public var apiKey: String?
    public var organisationSlug: String?
    public var environment: String?
    public var release: String?
    public var hasConsent: (@Sendable (RoboboroPrivacySignals) -> Bool)?
    public var flushInterval: TimeInterval
    /// Record uncaught Objective-C exceptions as `.fatal` events, stored and
    /// sent on next launch. Chains to any handler already installed.
    public var captureCrashes: Bool

    public init(
        siteId: String,
        apiBase: String,
        apiKey: String? = nil,
        organisationSlug: String? = nil,
        environment: String? = nil,
        release: String? = nil,
        hasConsent: (@Sendable (RoboboroPrivacySignals) -> Bool)? = nil,
        flushInterval: TimeInterval = RoboboroCore.defaultFlushInterval,
        captureCrashes: Bool = true
    ) {
        self.siteId = siteId
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.organisationSlug = organisationSlug
        self.environment = environment
        self.release = release
        self.hasConsent = hasConsent
        self.flushInterval = flushInterval
        self.captureCrashes = captureCrashes
    }
}

/// Heterogeneous JSON for `data` / breadcrumb payloads.
public enum RoboboroJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RoboboroJSON])
    case array([RoboboroJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .number(Double(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: RoboboroJSON].self) { self = .object(o); return }
        if let a = try? c.decode([RoboboroJSON].self) { self = .array(a); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public static func from(_ any: Any?) -> RoboboroJSON {
        switch any {
        case nil: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let d as Double: return .number(d)
        case let f as Float: return .number(Double(f))
        case let dict as [String: Any]:
            return .object(dict.mapValues { from($0) })
        case let arr as [Any]:
            return .array(arr.map { from($0) })
        default:
            return .string(String(describing: any!))
        }
    }
}
