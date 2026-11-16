import Foundation

public enum RoboboroTransportError: Error, Equatable {
    case badURL
    case http(Int)
}

public protocol RoboboroTransporting: AnyObject, Sendable {
    func send(url: URL, apiKey: String?, body: Data) async throws
}

public final class RoboboroURLSessionTransport: RoboboroTransporting, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(url: URL, apiKey: String?, body: Data) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        req.timeoutInterval = 10
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RoboboroTransportError.http(0)
        }
        // 202 (Next BFF) and 2xx from sublime-go are success. The BFF returns
        // 502 when sublime-go rejects or fails. 400 / 413 are dropped by the
        // tracker; everything else requeues with backoff.
        guard (200..<300).contains(http.statusCode) else {
            throw RoboboroTransportError.http(http.statusCode)
        }
    }
}

/// How a failed send is treated.
public enum RoboboroRetry {
    /// 400 and 413 mean the server will never take this chunk: drop it.
    /// 429, 5xx, and network errors are retried with backoff.
    public static func isPermanent(_ error: Error) -> Bool {
        if case RoboboroTransportError.http(let status) = error {
            return status == 400 || status == 413
        }
        if case RoboboroTransportError.badURL = error { return true }
        return false
    }
}

public enum RoboboroPost {
    public static func encode(
        batch: RoboboroBatch,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(batch)
    }
}
