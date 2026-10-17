// Owner: Maxwell. Head-to-head benchmark instrumentation. Every trial is one
// real task ("find the microwave start button") timed from start to the
// tester's success/fail tap, with the counts that make products comparable:
// time to first useful cue, prompts the user had to give, cloud calls, and
// whether it ran offline. The same task sheet is run on competitor apps by
// hand (benchmarks/PROTOCOL.md) and both land in one CSV.

import Foundation

public struct TrialResult: Sendable, Codable, Equatable {
    public var product: String
    public var task: String
    public var mode: String
    public var startedAt: Date
    public var durationS: Double
    public var success: Bool
    /// Start of trial to the first thing the user heard or felt.
    public var firstCueMs: Double?
    /// Sentences the product spoke during the trial.
    public var spokenLines: Int
    /// Times the user had to tap, speak or otherwise prompt it.
    public var userPrompts: Int
    public var cloudCalls: Int
    public var offline: Bool
    public var notes: String

    public init(product: String, task: String, mode: String, startedAt: Date, durationS: Double, success: Bool,
                firstCueMs: Double?, spokenLines: Int, userPrompts: Int, cloudCalls: Int, offline: Bool, notes: String) {
        self.product = product
        self.task = task
        self.mode = mode
        self.startedAt = startedAt
        self.durationS = durationS
        self.success = success
        self.firstCueMs = firstCueMs
        self.spokenLines = spokenLines
        self.userPrompts = userPrompts
        self.cloudCalls = cloudCalls
        self.offline = offline
        self.notes = notes
    }

    public static let csvHeader = "product,task,mode,started_at,duration_s,success,first_cue_ms,spoken_lines,user_prompts,cloud_calls,offline,notes"

    public var csvRow: String {
        let iso = ISO8601DateFormatter().string(from: startedAt)
        let cue = firstCueMs.map { String(format: "%.0f", $0) } ?? ""
        return [Self.q(product), Self.q(task), mode, iso, String(format: "%.2f", durationS), success ? "1" : "0", cue,
                "\(spokenLines)", "\(userPrompts)", "\(cloudCalls)", offline ? "1" : "0", Self.q(notes)].joined(separator: ",")
    }

    static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// The standard task battery. Same tasks, same order, every product.
public enum BenchmarkTasks {
    public static let all: [(task: String, mode: String)] = [
        ("Find and press the Start button on a microwave or labelled panel", "find"),
        ("Find a specific product on a table of five (by its label)", "find"),
        ("Read the first line of a printed letter", "read"),
        ("Identify a packaged food by its barcode", "find"),
        ("Walk 5 m down a corridor and get warned before a chair in the path", "explore"),
        ("Say what is on the table without asking a question", "explore"),
        ("Describe the room in one request", "describe"),
        ("Same as task 1 in Airplane Mode", "find"),
    ]
}

public actor TrialRecorder {
    public struct Active: Sendable {
        var product: String
        var task: String
        var mode: String
        var started: Date
        var startedUptime: Double
        var firstCue: Double?
        var spoken = 0
        var prompts = 0
        var cloud = 0
        var offline: Bool
    }

    private var active: Active?
    public private(set) var results: [TrialResult] = []
    private let storeURL: URL?

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            results = (try? d.decode([TrialResult].self, from: data)) ?? []
        }
    }

    public var isRunning: Bool { active != nil }
    public var currentTask: String? { active?.task }

    public func start(task: String, mode: String, product: String = "EchoGuide", offline: Bool) {
        active = Active(product: product, task: task, mode: mode, started: Date(), startedUptime: Self.uptime(), offline: offline)
    }

    public func noteSpoken() {
        guard active != nil else { return }
        active!.spoken += 1
        if active!.firstCue == nil { active!.firstCue = (Self.uptime() - active!.startedUptime) * 1000 }
    }

    /// A haptic cue also counts as the first useful cue.
    public func noteHaptic() {
        guard active != nil, active!.firstCue == nil else { return }
        active!.firstCue = (Self.uptime() - active!.startedUptime) * 1000
    }

    public func notePrompt() { if active != nil { active!.prompts += 1 } }
    public func noteCloudCall() { if active != nil { active!.cloud += 1 } }

    @discardableResult
    public func finish(success: Bool, notes: String = "") -> TrialResult? {
        guard let a = active else { return nil }
        active = nil
        let r = TrialResult(product: a.product, task: a.task, mode: a.mode, startedAt: a.started,
                            durationS: Self.uptime() - a.startedUptime, success: success, firstCueMs: a.firstCue,
                            spokenLines: a.spoken, userPrompts: a.prompts, cloudCalls: a.cloud, offline: a.offline, notes: notes)
        results.append(r)
        save()
        return r
    }

    /// Add a trial timed by hand on another product (same columns).
    public func addManual(_ r: TrialResult) {
        results.append(r)
        save()
    }

    public func clear() {
        results = []
        save()
    }

    public var csv: String { ([TrialResult.csvHeader] + results.map(\.csvRow)).joined(separator: "\n") + "\n" }

    private func save() {
        guard let storeURL else { return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(results).write(to: storeURL, options: .atomic)
    }

    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
