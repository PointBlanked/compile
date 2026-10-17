// Owner: Maxwell. One JSON file per home sets up its tools, so a care
// provider can configure a new home without a code change. Secrets are named
// here, never stored here: the app resolves them from the Keychain.
//
// {
//   "homeAssistant": { "baseURL": "http://homeassistant.local:8123", "tokenSecret": "ha_token",
//     "entities": [ { "name": "microwave_start", "doneSentence": "Microwave started.",
//                     "entityId": "switch.microwave", "service": "switch.turn_on",
//                     "textContains": ["start"], "sideEffect": "physical" } ] },
//   "productLookup": true,
//   "remoteServers": [ { "endpoint": "https://plugins.example.com/mcp",
//                        "claims": { "thermostat_set": { "labels": ["thermostat"] } },
//                        "sideEffects": { "thermostat_set": "reversible" } } ]
// }

import Foundation
import EchoGuideContracts

public struct PluginManifest: Sendable, Codable, Equatable {
    public struct HomeAssistant: Sendable, Codable, Equatable {
        public var baseURL: URL
        public var tokenSecret: String
        public var entities: [HomeAssistantEntity]
    }

    public struct Claim: Sendable, Codable, Equatable {
        public var labels: [String]?
        public var textContains: [String]?
        public var barcodePrefixes: [String]?

        var toolClaim: ToolClaim {
            ToolClaim(labels: Set(labels ?? []), textContains: textContains ?? [], barcodePrefixes: barcodePrefixes ?? [])
        }
    }

    public struct RemoteServer: Sendable, Codable, Equatable {
        public var endpoint: URL
        public var claims: [String: Claim]?
        public var sideEffects: [String: ToolSideEffect]?
        /// Name of a secret sent as `Authorization: Bearer`.
        public var tokenSecret: String?
    }

    public var homeAssistant: HomeAssistant?
    public var productLookup: Bool?
    public var remoteServers: [RemoteServer]?

    public static func load(_ data: Data) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}

public struct InstalledPlugins: Sendable {
    /// Remote servers that could not be reached; their tools are missing until retried.
    public var failedRemotes: [URL]
}

extension PluginRegistry {
    /// Registers every tool the manifest describes. Local tools first, so a
    /// remote server cannot shadow a built-in by registering the same name.
    @discardableResult
    public func install(_ manifest: PluginManifest, secrets: @escaping SecretProvider,
                        transport: HTTPTransport = URLSessionTransport()) async -> InstalledPlugins {
        var installed = InstalledPlugins(failedRemotes: [])

        if let ha = manifest.homeAssistant {
            let secret = ha.tokenSecret
            for tool in HomeAssistantPlugin.tools(baseURL: ha.baseURL, entities: ha.entities, transport: transport,
                                                  token: { await secrets(secret) }) {
                register(tool)
            }
        }

        if manifest.productLookup == true {
            register(await ProductLookupPlugin(transport: transport).tool)
        }

        let local = Set(toolNames)
        for server in manifest.remoteServers ?? [] {
            var headers: [String: String] = [:]
            if let name = server.tokenSecret, let token = await secrets(name) { headers["Authorization"] = "Bearer \(token)" }
            let client = MCPHTTPClient(endpoint: server.endpoint, headers: headers)
            do {
                try await registerRemote(client, claims: (server.claims ?? [:]).mapValues(\.toolClaim),
                                         sideEffects: server.sideEffects ?? [:], skipping: local)
            } catch {
                installed.failedRemotes.append(server.endpoint)
            }
        }
        return installed
    }
}
