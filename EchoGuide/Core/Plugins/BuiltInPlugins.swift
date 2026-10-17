// Owner: Maxwell. The first real tools, chosen for the differentiation plan:
//
//  * HomeAssistantPlugin   press the button for the user (microwave, kettle,
//                          lights, thermostat) through one Home Assistant hub,
//                          which already integrates thousands of appliances.
//  * ProductLookupPlugin   barcode -> product name and allergens (Open Food Facts).

import Foundation
import EchoGuideContracts

/// Looks up a secret (token, signing key) by name. Keychain in the app; a
/// dictionary in tests. Secrets never live in the manifest.
public typealias SecretProvider = @Sendable (String) async -> String?

// MARK: - Home Assistant

public struct HomeAssistantEntity: Sendable, Equatable, Codable {
    /// Tool name, e.g. "microwave_start".
    public var name: String
    /// What the user hears after it worked: "Microwave started."
    public var doneSentence: String
    public var entityId: String
    /// Home Assistant service, "domain.service", e.g. "switch.turn_on".
    public var service: String
    public var labels: [String]?
    public var textContains: [String]?
    public var sideEffect: ToolSideEffect

    public init(name: String, doneSentence: String, entityId: String, service: String,
                labels: [String]? = nil, textContains: [String]? = nil, sideEffect: ToolSideEffect = .physical) {
        self.name = name
        self.doneSentence = doneSentence
        self.entityId = entityId
        self.service = service
        self.labels = labels
        self.textContains = textContains
        self.sideEffect = sideEffect
    }
}

public enum HomeAssistantPlugin {
    /// One tool per entity. Calls `POST {base}/api/services/{domain}/{service}`
    /// with a long-lived access token.
    public static func tools(baseURL: URL, entities: [HomeAssistantEntity], transport: HTTPTransport,
                             token: @escaping @Sendable () async -> String?) -> [ToolDescriptor] {
        entities.compactMap { e in
            let parts = e.service.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let url = baseURL.appendingPathComponent("api/services/\(parts[0])/\(parts[1])")
            return ToolDescriptor(
                name: e.name,
                description: "Home Assistant \(e.service) on \(e.entityId)",
                sideEffect: e.sideEffect,
                claim: ToolClaim(labels: Set(e.labels ?? []), textContains: e.textContains ?? [])
            ) { _ in
                _ = try await transport.postJSON(url, body: ["entity_id": e.entityId], bearer: await token())
                return e.doneSentence
            }
        }
    }
}

// MARK: - Product lookup

public actor ProductLookupPlugin {
    private let transport: HTTPTransport
    private let base: URL
    private var cache: [String: String] = [:]

    public init(transport: HTTPTransport, base: URL = URL(string: "https://world.openfoodfacts.org")!) {
        self.transport = transport
        self.base = base
    }

    public var tool: ToolDescriptor {
        ToolDescriptor(name: "lookup_product", description: "Say the product name and allergens for a barcode",
                       sideEffect: .none, claim: ToolClaim(anyBarcode: true), parameters: ["text"]) { [self] args in
            await self.describe(args["text"] ?? "")
        }
    }

    public func describe(_ code: String) async -> String {
        // QR codes and other payloads are not product codes; never send them off-device.
        guard (8...14).contains(code.count), code.allSatisfy(\.isNumber) else {
            if let host = URL(string: code)?.host { return "QR code for \(host)." }
            return "This code is not a product barcode."
        }
        if let hit = cache[code] { return hit }

        let url = base.appendingPathComponent("api/v2/product/\(code)")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "product_name,brands,allergens_tags")]
        do {
            let json = try await transport.getJSON(comps.url!, headers: ["User-Agent": "EchoGuide/0.1 (accessibility app)"])
            guard let product = json["product"] as? [String: Any], let name = product["product_name"] as? String, !name.isEmpty else {
                return "I could not find this product."
            }
            let brand = (product["brands"] as? String)?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            var sentence = [brand, name].compactMap { $0 }.joined(separator: " ") + "."
            let allergens = (product["allergens_tags"] as? [String] ?? []).map { $0.split(separator: ":").last.map(String.init) ?? $0 }
            if !allergens.isEmpty { sentence += " Contains \(allergens.prefix(4).joined(separator: ", "))." }
            cache[code] = sentence
            return sentence
        } catch {
            return "I cannot look this up right now."
        }
    }
}
