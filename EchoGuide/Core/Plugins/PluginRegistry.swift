// Owner: Maxwell. Tool layer speaking the Model Context Protocol.
//
//  * Local tools: Swift handlers registered in-process, exposed through MCP
//    `tools/list` and `tools/call` JSON-RPC so any MCP client can drive them.
//  * Remote tools: plugin servers written with FastMCP (Python) or any MCP
//    server, reached over the Streamable HTTP transport by MCPHTTPClient.
//
// Each tool declares which detections it claims (labels, text, barcode
// prefixes) and its side effect; AutomationEngine never calls a physical tool
// without the dwell confirmation.

import Foundation
import EchoGuideContracts

// MARK: - JSON

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Tools

public struct ToolClaim: Sendable, Equatable {
    public var labels: Set<String> = []
    /// Case-insensitive substrings of recognised text ("start", "defrost").
    public var textContains: [String] = []
    public var barcodePrefixes: [String] = []

    public init(labels: Set<String> = [], textContains: [String] = [], barcodePrefixes: [String] = []) {
        self.labels = labels
        self.textContains = textContains
        self.barcodePrefixes = barcodePrefixes
    }

    func claims(_ d: Detection) -> Bool {
        if labels.contains(d.label) { return true }
        guard let text = d.text?.lowercased() else { return false }
        if d.kind == .barcode { return barcodePrefixes.contains { text.hasPrefix($0.lowercased()) } }
        return textContains.contains { text.contains($0.lowercased()) }
    }
}

public struct ToolDescriptor: Sendable {
    public typealias Handler = @Sendable ([String: String]) async throws -> String

    public var name: String
    public var description: String
    public var sideEffect: ToolSideEffect
    public var claim: ToolClaim
    /// Argument names, all strings; published as the MCP inputSchema.
    public var parameters: [String]
    public var handler: Handler

    public init(name: String, description: String, sideEffect: ToolSideEffect, claim: ToolClaim = ToolClaim(),
                parameters: [String] = [], handler: @escaping Handler) {
        self.name = name
        self.description = description
        self.sideEffect = sideEffect
        self.claim = claim
        self.parameters = parameters
        self.handler = handler
    }

    var inputSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0, .object(["type": .string("string")])) })),
            "required": .array(parameters.map(JSONValue.string)),
        ])
    }
}

public enum PluginError: Error, Equatable {
    case unknownTool(String)
    case remote(String)
}

public actor PluginRegistry: ToolInvoking {
    private var tools: [String: ToolDescriptor] = [:]
    private var order: [String] = []

    public init() {}

    public func register(_ tool: ToolDescriptor) {
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    /// Pull every tool from a remote MCP server and proxy calls to it.
    /// Remote tools claim detections through `claims`, keyed by tool name,
    /// because MCP has no notion of "what this tool can see".
    public func registerRemote(_ client: MCPHTTPClient, claims: [String: ToolClaim], sideEffects: [String: ToolSideEffect] = [:]) async throws {
        for remote in try await client.listTools() {
            register(ToolDescriptor(
                name: remote.name,
                description: remote.description,
                sideEffect: sideEffects[remote.name] ?? .physical, // unknown = treat as most dangerous
                claim: claims[remote.name] ?? ToolClaim(),
                parameters: remote.parameters
            ) { args in try await client.callTool(remote.name, arguments: args) })
        }
    }

    public var toolNames: [String] { order }

    // MARK: ToolInvoking

    public func match(_ detection: Detection) -> ToolMatch? {
        for name in order {
            guard let t = tools[name], t.claim.claims(detection) else { continue }
            var args: [String: String] = [:]
            if t.parameters.contains("label") { args["label"] = detection.label }
            if t.parameters.contains("text"), let text = detection.text { args["text"] = text }
            return ToolMatch(toolName: t.name, sideEffect: t.sideEffect, arguments: args)
        }
        return nil
    }

    public func invoke(_ match: ToolMatch) async throws -> String {
        guard let t = tools[match.toolName] else { throw PluginError.unknownTool(match.toolName) }
        return try await t.handler(match.arguments)
    }

    // MARK: MCP server surface (JSON-RPC 2.0)

    /// Handles one MCP JSON-RPC request. Returns nil for notifications.
    public func handle(_ request: Data) async -> Data? {
        guard let req = try? JSONDecoder().decode(JSONValue.self, from: request),
              let method = req["method"]?.stringValue else {
            return encode(rpcError(id: .null, code: -32700, message: "Parse error"))
        }
        let id = req["id"] ?? .null
        if case .null = id, method.hasPrefix("notifications/") { return nil }

        switch method {
        case "initialize":
            return encode(rpcResult(id: id, .object([
                "protocolVersion": .string(MCP.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("echoguide"), "version": .string("0.1.0")]),
            ])))
        case "tools/list":
            let list: [JSONValue] = order.compactMap { tools[$0] }.map {
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema])
            }
            return encode(rpcResult(id: id, .object(["tools": .array(list)])))
        case "tools/call":
            guard let name = req["params"]?["name"]?.stringValue else {
                return encode(rpcError(id: id, code: -32602, message: "Missing tool name"))
            }
            var args: [String: String] = [:]
            if case .object(let o)? = req["params"]?["arguments"] {
                for (k, v) in o { if let s = v.stringValue { args[k] = s } }
            }
            guard let t = tools[name] else {
                return encode(rpcError(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            do {
                let text = try await t.handler(args)
                return encode(rpcResult(id: id, MCP.textContent(text, isError: false)))
            } catch {
                // MCP reports tool failures as results with isError, not protocol errors.
                return encode(rpcResult(id: id, MCP.textContent(String(describing: error), isError: true)))
            }
        default:
            return encode(rpcError(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func rpcResult(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    private func encode(_ v: JSONValue) -> Data? { try? JSONEncoder().encode(v) }
}

enum MCP {
    static let protocolVersion = "2025-06-18"

    static func textContent(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }
}

// MARK: - Remote MCP client (Streamable HTTP)

public actor MCPHTTPClient {
    public struct RemoteTool: Sendable { public var name, description: String; public var parameters: [String] }

    private let endpoint: URL
    private let session: URLSession
    private let headers: [String: String]
    private var sessionID: String?
    private var initialized = false
    private var nextID = 1

    /// `endpoint` is the server's MCP path, e.g. `https://plugins.example.com/mcp`
    /// for `fastmcp run server.py --transport http`.
    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    public func listTools() async throws -> [RemoteTool] {
        try await ensureInitialized()
        let result = try await call("tools/list", params: .object([:]))
        guard case .array(let tools)? = result["tools"] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"]?.stringValue else { return nil }
            var params: [String] = []
            if case .object(let props)? = t["inputSchema"]?["properties"] { params = props.keys.sorted() }
            return RemoteTool(name: name, description: t["description"]?.stringValue ?? "", parameters: params)
        }
    }

    public func callTool(_ name: String, arguments: [String: String]) async throws -> String {
        try await ensureInitialized()
        let result = try await call("tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments.mapValues(JSONValue.string)),
        ]))
        var text = ""
        if case .array(let content)? = result["content"] {
            text = content.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
        }
        if case .bool(true)? = result["isError"] { throw PluginError.remote(text) }
        return text
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        _ = try await call("initialize", params: .object([
            "protocolVersion": .string(MCP.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("echoguide"), "version": .string("0.1.0")]),
        ]))
        try await post(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        initialized = true
    }

    private func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let data = try await post(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params,
        ]))
        guard let data else { throw PluginError.remote("Empty response to \(method)") }
        let msg = try JSONDecoder().decode(JSONValue.self, from: data)
        if let err = msg["error"] { throw PluginError.remote(err["message"]?.stringValue ?? "MCP error") }
        return msg["result"] ?? .null
    }

    @discardableResult
    private func post(_ body: JSONValue) async throws -> Data? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCP.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw PluginError.remote("No HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        if http.statusCode == 202 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw PluginError.remote("HTTP \(http.statusCode)") }

        // Streamable HTTP may answer as SSE; the JSON-RPC response is the last `data:` event.
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            let payload = lines.last { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            return payload.map { Data($0.utf8) }
        }
        return data
    }
}
