import Foundation

public enum RoboboroTransportError: Error, Equatable {
    case badURL
    case http(Int)
}

public protocol RoboboroTransporting: AnyObject, Sendable {
    func send(url: URL, apiKey: String?, body: Data) async throws
}

/// A redirect is followed only when both URLs are https and the host is unchanged.
public enum RoboboroRedirect {
    public static func follows(from: URL?, to: URL?) -> Bool {
        guard let from, let to else { return false }
        guard from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "https" else {
            return false
        }
        guard let fromHost = from.host?.lowercased(), let toHost = to.host?.lowercased() else {
            return false
        }
        return fromHost == toHost
    }
}

private final class RoboboroRedirector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard RoboboroRedirect.follows(from: task.originalRequest?.url, to: request.url) else {
            return nil
        }
        return request
    }
}

public final class RoboboroURLSessionTransport: RoboboroTransporting, @unchecked Sendable {
    private let session: URLSession
    /// Keeps the redirect delegate alive for the session.
    private let redirector: RoboboroRedirector?

    /// Ephemeral session: no cookies, no cache, and no redirect onto another host.
    public init() {
        let redirector = RoboboroRedirector()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        self.redirector = redirector
        self.session = URLSession(configuration: config, delegate: redirector, delegateQueue: nil)
    }

    public init(session: URLSession) {
        self.session = session
        self.redirector = nil
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
        // 502 when sublime-go rejects or fails. A refused redirect completes as
        // the original 3xx. 400 / 413 are dropped by the tracker; everything
        // else requeues with backoff.
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

    /// `http 502`, or the network error's own words, for a log line.
    public static func describe(_ error: Error) -> String {
        if case RoboboroTransportError.http(let status) = error { return "http \(status)" }
        if case RoboboroTransportError.badURL = error { return "bad URL" }
        return error.localizedDescription
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
