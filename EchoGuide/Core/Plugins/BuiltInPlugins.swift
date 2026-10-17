// Owner: Maxwell. The first real tools, chosen for the differentiation plan:
//
//  * HomeAssistantPlugin   press the button for the user (microwave, kettle,
//                          lights, thermostat) through one Home Assistant hub,
//                          which already integrates thousands of appliances.
//  * CaregiverAlerts       tell the carer when the location fence trips. Alerts
//                          are written to a disk outbox first, so one sent
//                          offline is delivered when the phone reconnects.
//  * ProductLookupPlugin   barcode -> product name and allergens (Open Food Facts).

import Foundation
import EchoGuideContracts
#if canImport(CryptoKit)
import CryptoKit
#endif

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

// MARK: - Caregiver alerts

public struct CaregiverAlert: Sendable, Equatable, Codable {
    public var id: UUID
    public var event: String
    public var region: String
    public var at: Date
}

/// Thrown when the alert is safely queued but not yet delivered, so the caller
/// does not tell the user "your carer has been told" when that is not true yet.
public struct CaregiverAlertQueued: Error, Equatable {}

public actor CaregiverAlerts {
    private let webhook: URL
    private let transport: HTTPTransport
    private let outboxURL: URL?
    private let signingSecret: String?
    private var outbox: [CaregiverAlert]

    /// `outboxURL` persists undelivered alerts across app launches; nil keeps
    /// them in memory only (tests).
    public init(webhook: URL, transport: HTTPTransport, outboxURL: URL?, signingSecret: String? = nil) {
        self.webhook = webhook
        self.transport = transport
        self.outboxURL = outboxURL
        self.signingSecret = signingSecret
        if let outboxURL, let data = try? Data(contentsOf: outboxURL),
           let saved = try? Self.decoder.decode([CaregiverAlert].self, from: data) {
            outbox = saved
        } else {
            outbox = []
        }
    }

    public var pending: Int { outbox.count }

    /// Queue, then try to deliver everything queued. True when this alert went out.
    @discardableResult
    public func send(event: String, region: String, at date: Date = Date()) async -> Bool {
        let alert = CaregiverAlert(id: UUID(), event: event, region: region, at: date)
        outbox.append(alert)
        save()
        await flush()
        return !outbox.contains(alert)
    }

    /// Call on reconnect (NWPathMonitor) and on app launch.
    public func flush() async {
        var remaining: [CaregiverAlert] = []
        for alert in outbox {
            do {
                try await deliver(alert)
            } catch {
                remaining.append(alert)
            }
        }
        outbox = remaining
        save()
    }

    public var tool: ToolDescriptor {
        ToolDescriptor(name: "notify_caregiver", description: "Tell the carer the user left a safe area",
                       sideEffect: .none, parameters: ["region"]) { [self] args in
            let delivered = await self.send(event: "left_safe_area", region: args["region"] ?? "safe area")
            if !delivered { throw CaregiverAlertQueued() }
            return "Your carer has been told."
        }
    }

    private func deliver(_ alert: CaregiverAlert) async throws {
        var req = URLRequest(url: webhook)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The receiver dedupes on this, so a retry after a lost response is safe.
        req.setValue(alert.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let body = try Self.encoder.encode(alert)
        req.httpBody = body
        if let signingSecret { req.setValue(Self.signature(body, secret: signingSecret), forHTTPHeaderField: "X-EchoGuide-Signature") }
        let (_, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
    }

    private func save() {
        guard let outboxURL, let data = try? Self.encoder.encode(outbox) else { return }
        try? data.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Hex HMAC-SHA256 of the body, so the receiver can reject forged alerts.
    static func signature(_ body: Data, secret: String) -> String {
        #if canImport(CryptoKit)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
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
