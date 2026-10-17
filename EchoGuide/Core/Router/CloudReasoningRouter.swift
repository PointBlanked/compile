// Owner: Maxwell. Decides local vs cloud for one reasoning query and never
// lets the cloud make the app worse than local:
//   * local confidence >= threshold        -> answered locally, no network
//   * offline / no consent / breaker open  -> local fallback, flagged
//   * otherwise                            -> provider, under a hard timeout
// Keys never ship in the app: providers point at a proxy you run, which holds
// the real Gemini / OpenAI keys and rate-limits per device.

import Foundation
import EchoGuideContracts

public struct CloudRouterConfig: Sendable {
    public var confidenceThreshold: Float = 0.85
    /// Hard ceiling; past this the local answer is spoken instead.
    public var timeout: TimeInterval = 2.5
    /// Consecutive failures that open the breaker, and how long it stays open.
    public var breakerFailures = 3
    public var breakerCooldown: TimeInterval = 60
    /// Per-session ceiling on cloud calls (cost guard).
    public var maxCallsPerSession = 200
    /// Camera images leave the device only when the user has agreed.
    public var imageConsent = false

    public init() {}
}

/// One cloud model behind the router. Swap Gemini / OpenAI / anything.
public protocol ReasoningProvider: Sendable {
    func answer(_ query: ReasoningQuery, includeImage: Bool) async throws -> String
}

public protocol Connectivity: Sendable {
    func isOnline() async -> Bool
}

public actor CloudReasoningRouter: ReasoningRouting {
    private let config: CloudRouterConfig
    private let provider: ReasoningProvider?
    private let connectivity: Connectivity
    private var failures = 0
    private var breakerOpenedAt: Date?
    private var calls = 0
    public private(set) var latency = LatencyWindow()

    public init(config: CloudRouterConfig = CloudRouterConfig(), provider: ReasoningProvider?, connectivity: Connectivity) {
        self.config = config
        self.provider = provider
        self.connectivity = connectivity
    }

    public func resolve(_ query: ReasoningQuery) async -> ReasoningOutcome {
        let timer = FrameTimer()
        let local = Self.localAnswer(query)

        if query.localConfidence >= config.confidenceThreshold {
            return ReasoningOutcome(answer: local, source: .local, latencyMs: timer.elapsedMs)
        }
        guard let provider, calls < config.maxCallsPerSession, !breakerOpen, await connectivity.isOnline() else {
            return ReasoningOutcome(answer: local, source: .localFallback, latencyMs: timer.elapsedMs)
        }

        calls += 1
        let includeImage = config.imageConsent && query.jpeg != nil
        let timeout = config.timeout
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await provider.answer(query, includeImage: includeImage) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw RouterError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw RouterError.timeout }
                return first
            }
            failures = 0
            let ms = timer.elapsedMs
            latency.record(ms)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningOutcome(answer: trimmed.isEmpty ? local : trimmed, source: trimmed.isEmpty ? .localFallback : .cloud, latencyMs: ms)
        } catch {
            failures += 1
            if failures >= config.breakerFailures { breakerOpenedAt = Date() }
            return ReasoningOutcome(answer: local, source: .localFallback, latencyMs: timer.elapsedMs)
        }
    }

    private var breakerOpen: Bool {
        guard let opened = breakerOpenedAt else { return false }
        if Date().timeIntervalSince(opened) >= config.breakerCooldown {
            breakerOpenedAt = nil
            failures = 0
            return false
        }
        return true
    }

    /// Best on-device sentence from detections alone. Always available.
    static func localAnswer(_ q: ReasoningQuery) -> String {
        guard let top = q.detections.max(by: { $0.confidence < $1.confidence }) else { return "I am not sure what this is." }
        let name = top.kind == .text ? (top.text ?? "Some text") : top.label
        return q.localConfidence >= 0.6 ? "This looks like \(name)." : "This might be \(name)."
    }

    enum RouterError: Error { case timeout }
}

// MARK: - Providers

/// Gemini `generateContent` through your proxy. The proxy forwards to
/// `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
public struct GeminiProvider: ReasoningProvider {
    public var proxyBase: URL
    public var model: String
    public var deviceToken: @Sendable () async -> String?

    public init(proxyBase: URL, model: String = "gemini-2.5-flash", deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
        self.deviceToken = deviceToken
    }

    public func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        var parts: [[String: Any]] = [["text": Prompt.text(q)]]
        if includeImage, let jpeg = q.jpeg {
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": 40, "temperature": 0.2],
        ]
        let url = proxyBase.appendingPathComponent("v1beta/models/\(model):generateContent")
        let json = try await HTTP.postJSON(url, body: body, token: await deviceToken())
        let candidates = json["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let textParts = content?["parts"] as? [[String: Any]]
        return textParts?.compactMap { $0["text"] as? String }.joined() ?? ""
    }
}

/// OpenAI Chat Completions (gpt-4o) through your proxy. For multi-turn voice,
/// the Realtime API is a separate WebSocket session and not routed here.
public struct OpenAIProvider: ReasoningProvider {
    public var proxyBase: URL
    public var model: String
    public var deviceToken: @Sendable () async -> String?

    public init(proxyBase: URL, model: String = "gpt-4o", deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.model = model
        self.deviceToken = deviceToken
    }

    public func answer(_ q: ReasoningQuery, includeImage: Bool) async throws -> String {
        var content: [[String: Any]] = [["type": "text", "text": Prompt.text(q)]]
        if includeImage, let jpeg = q.jpeg {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "low"]])
        }
        let body: [String: Any] = ["model": model, "max_tokens": 40, "temperature": 0.2, "messages": [["role": "user", "content": content]]]
        let json = try await HTTP.postJSON(proxyBase.appendingPathComponent("v1/chat/completions"), body: body, token: await deviceToken())
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }
}

enum Prompt {
    static func text(_ q: ReasoningQuery) -> String {
        let seen = q.detections.map { d in
            "\(d.kind == .text ? "text \"\(d.text ?? "")\"" : d.label) (\(Int(d.confidence * 100))%)"
        }.joined(separator: ", ")
        return """
        You guide a blind or cognitively impaired person, one step at a time. \
        On-device vision saw: \(seen). \(q.question) \
        Answer in one short plain sentence, no lists, under eight words.
        """
    }
}

enum HTTP {
    static func postJSON(_ url: URL, body: [String: Any], token: String?) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

#if canImport(Network)
import Network

/// NWPathMonitor-backed connectivity. Airplane Mode reads as offline instantly.
public final class PathConnectivity: Connectivity, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = false

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.online = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "echoguide.network"))
    }

    deinit { monitor.cancel() }

    public func isOnline() async -> Bool {
        lock.withLock { online }
    }
}
#endif
