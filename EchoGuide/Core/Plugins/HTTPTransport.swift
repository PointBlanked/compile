// Owner: Maxwell. One HTTP seam for every network call in Infra (cloud
// providers, plugins), so tests run against a stub and the app can add
// certificate pinning or a proxy in one place.

import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct HTTPStatusError: Error, Equatable {
    public var status: Int
}

extension HTTPTransport {
    /// POST a JSON object, expect 2xx, return the decoded object (empty for no body).
    func postJSON(_ url: URL, body: [String: Any], bearer: String?, timeout: TimeInterval = 4) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func getJSON(_ url: URL, timeout: TimeInterval = 4, headers: [String: String] = [:]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
