// Owner: Maxwell. Everything the app reads at launch: the per-home config
// file, secrets from the Keychain, and the vision model.

import CoreML
import Foundation
import Security
import EchoGuideInfra
import EchoGuideVision

/// Per-home setup. Lives at Application Support/echoguide.json (written by the
/// care provider's setup flow); the bundled sample is the fallback.
struct AppConfig: Decodable {
    var plugins: PluginManifest?
    var safeAreas: [SafeArea]?
    /// Start narrowed to one task ("start"), nil for open scanning.
    var goal: String?

    static func load() -> AppConfig {
        let candidates = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("echoguide.json"),
            Bundle.main.url(forResource: "echoguide.sample", withExtension: "json"),
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return config
            }
        }
        return AppConfig()
    }
}

enum AppSettings {
    /// Proxy base URL from Info.plist (`EGProxyBaseURL`). Empty = no cloud at all.
    static var proxyBase: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "EGProxyBaseURL") as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static var imageConsent: Bool { UserDefaults.standard.bool(forKey: "cloudImageConsent") }
    static var voiceEnabled: Bool { UserDefaults.standard.bool(forKey: "voiceEnabled") }
    static var elevenLabsVoiceID: String? { UserDefaults.standard.string(forKey: "elevenLabsVoiceID") }
    static var isBenchmark: Bool { ProcessInfo.processInfo.arguments.contains("-benchmark") }
}

/// Generic-password Keychain items, service "EchoGuide". The setup flow writes
/// `device_token` (proxy auth) and any secret a manifest names.
enum Keychain {
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "EchoGuide",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "EchoGuide",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Finds the YOLO model. Ships as `Resources/Models/<name>.mlpackage` (copied
/// as a folder, not compiled by Xcode), compiled on first launch and cached.
enum ModelStore {
    static let names = ["yolo11n", "yolov8n"]

    static func locate() -> URL? {
        let fm = FileManager.default
        guard let cacheDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Models") else { return nil }
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for name in names {
            let cached = cacheDir.appendingPathComponent("\(name).mlmodelc")
            if fm.fileExists(atPath: cached.path) { return cached }
            if let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return compiled }

            let models = Bundle.main.resourceURL?.appendingPathComponent("Models")
            guard let package = models?.appendingPathComponent("\(name).mlpackage"), fm.fileExists(atPath: package.path),
                  let temp = try? MLModel.compileModel(at: package) else { continue }
            try? fm.removeItem(at: cached)
            if (try? fm.moveItem(at: temp, to: cached)) != nil { return cached }
            return temp
        }
        return nil
    }
}
