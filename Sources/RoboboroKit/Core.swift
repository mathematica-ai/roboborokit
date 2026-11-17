import CryptoKit
import Foundation

public enum RoboboroCore {
    public static let maxBatchSize = 50
    public static let maxPending = 100
    public static let defaultFlushInterval: TimeInterval = 5
    public static let optOutKey = "roboboro_optout"
    public static let pendingBufferKey = "roboboro_pending"
    public static let visitorKey = "roboboro_vid"
}

public enum RoboboroPlatform: String, Codable, Sendable {
    case web, native, playwright, node
}

public enum RoboboroLevel: String, Codable, Sendable {
    case fatal, error, warning, info, debug
}

public enum RoboboroTestStatus: String, Codable, Sendable {
    case PASSED, FAILED, SKIPPED
}

public enum RoboboroEventType: String, Codable, Sendable {
    case exception
    case message
    case testResult = "test_result"
    case breadcrumb
    case session
    case webVital = "web_vital"
}

public struct RoboboroPrivacySignals: Sendable {
    /// Always false on iOS (browser GPC/DNT N/A).
    public var gpc: Bool
    public var dnt: Bool
    public var optedOut: Bool
}

public enum RoboboroIDs {
    /// `rb_` + 12 random bytes as hex — parity with JS `generateId()`.
    public static func generateId(prefix: String = "rb") -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return prefix + "_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Same grouping key sublime-go / p1-website / JS `server.ts` use.
    public static func normalizeFingerprintInput(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// SHA-256 hex, first 16 characters.
    public static func fingerprint(_ input: String) -> String {
        let normalized = normalizeFingerprintInput(input)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RoboboroConsent {
    public static func granted(
        _ signals: RoboboroPrivacySignals,
        hasConsent: ((RoboboroPrivacySignals) -> Bool)?,
        overrideBrowserSignals: Bool = false
    ) -> Bool {
        if signals.optedOut { return false }
        let consented = hasConsent?(signals) ?? true
        if !consented { return false }
        if (signals.gpc || signals.dnt) && !overrideBrowserSignals { return false }
        return true
    }
}

public enum RoboboroURL {
    public static func ingest(_ apiBase: String) -> String {
        var trimmed = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/ingest") { return trimmed }
        return trimmed + "/ingest"
    }
}

public enum RoboboroErrorFields {
    public static func message(from error: Error) -> String {
        let ns = error as NSError
        let text = error.localizedDescription
        if !text.isEmpty { return text }
        if !ns.domain.isEmpty { return "\(ns.domain)#\(ns.code)" }
        return String(describing: error)
    }

    /// Locale-independent grouping key, so the same error groups together
    /// whatever the device language. `NSError`s use `domain#code`; Swift
    /// errors use the fully qualified type, plus the case name for enums
    /// (payloads are left out) or the bridged code otherwise.
    public static func fingerprintKey(from error: Error) -> String {
        let ns = error as NSError
        if type(of: error) is NSError.Type {
            return "\(ns.domain)#\(ns.code)"
        }
        let typeName = String(reflecting: type(of: error))
        if Mirror(reflecting: error).displayStyle == .enum {
            let described = String(describing: error)
            let caseName = described.split(separator: "(", maxSplits: 1).first.map(String.init) ?? described
            return "\(typeName).\(caseName)"
        }
        return "\(typeName)#\(ns.code)"
    }

    /// Drops addresses and numbers (indices, sizes) from an exception reason
    /// so one bug yields one fingerprint.
    static func stripVolatile(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "0x", options: .regularExpression)
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
    }

    public static func trace(from error: Error) -> String? {
        let ns = error as NSError
        if let stack = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return String(describing: stack)
        }
        let desc = String(describing: error)
        return desc.isEmpty ? nil : desc
    }
}
