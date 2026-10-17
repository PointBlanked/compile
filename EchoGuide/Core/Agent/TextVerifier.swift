// Owner: Maxwell's agent, extended for the demo (Bryan). OCR hands off to a
// second stage before anything is spoken or shown:
//
//   1. an instant local gate drops obvious nonsense (symbol soup, no vowels,
//      a language recogniser that cannot place it)
//   2. the language model corrects what is left ("STAR T" -> "START",
//      "M1CROWAVE" -> "MICROWAVE") or rejects it, under a short deadline
//
// Real-time rules: never on the frame path, one request in flight, results
// cached by input, and the local gate alone when the model is offline.

import Foundation
import EchoGuideContracts
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public actor TextVerifier {
    public var timeout: TimeInterval
    private var cache: [String: [String]] = [:]
    private var order: [String] = []
    public let cacheCapacity: Int

    public init(timeout: TimeInterval = 2.5, cacheCapacity: Int = 64) {
        self.timeout = timeout
        self.cacheCapacity = cacheCapacity
    }

    // MARK: - Local gate

    /// Cheap and strict: is this plausibly real text a person would want read?
    public static func plausible(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2 else { return false }
        // Two-character strings are debris unless they are a known short word or a number.
        if s.count == 2, !shortWords.contains(s.uppercased()), s.rangeOfCharacter(from: .decimalDigits) == nil { return false }
        let scalars = s.unicodeScalars
        let alnum = scalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard Double(alnum) / Double(scalars.count) >= 0.6 else { return false }
        // A short string with an odd symbol in it ("l|l1", "S+ART") is OCR debris; ordinary punctuation is fine ("No. 7").
        let punctuation = CharacterSet(charactersIn: ".,:;!?'%$£€&-/()")
        let odd = scalars.filter { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespaces.contains($0) && !punctuation.contains($0) }.count
        if s.count < 6, odd > 0 { return false }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if digits > 0, letters.count <= 2 { return true }               // "230", "4B"
        let lower = String(String.UnicodeScalarView(letters)).lowercased()
        let vowels = lower.filter { "aeiouy".contains($0) }.count
        // No vowel: only a known short word (TV, WC, PM) or a mostly-numeric string passes.
        if vowels == 0, letters.count > 0, !shortWords.contains(String(String.UnicodeScalarView(letters)).uppercased()), digits == 0 { return false }
        // Runs of consonants longer than five are not English words.
        var run = 0
        for c in lower {
            run = "aeiouy".contains(c) ? 0 : run + 1
            if run > 5 { return false }
        }
        #if canImport(NaturalLanguage)
        // For sentences, ask the language recogniser; single words are too short for it.
        if s.split(separator: " ").count >= 3 {
            let r = NLLanguageRecognizer()
            r.processString(s)
            let hyp = r.languageHypotheses(withMaximum: 3)
            let known = hyp.values.max() ?? 0
            if known < 0.15 { return false }
        }
        #endif
        return true
    }

    static let shortWords: Set<String> = ["TV", "WC", "PM", "AM", "ML", "KG", "CM", "MM", "KM", "HD", "OK", "ON", "NO", "GO", "UP", "DR", "ST", "MR", "MS", "EXIT", "WIFI", "ATM"]

    public static func gate(_ lines: [String]) -> [String] { lines.filter(plausible) }

    // MARK: - Model handoff

    /// Worked examples make a small text model reliable at this; sent raw,
    /// without the router's conversational framing.
    public static func question(_ lines: [String]) -> String {
        """
        You fix OCR output from signs and appliance panels. Rules: fix split or merged letters and digit/letter swaps \
        (0/O, 1/I, 5/S), never add words, drop lines that are not real words, keep the order, one line per output line, \
        and answer NONE only if nothing is real.
        Example input:
        STAR T
        5TOP
        l|l1
        Example output:
        START
        STOP

        Example input:
        PU5H TO 0PEN
        qzx vwk
        Example output:
        PUSH TO OPEN

        Input:
        \(lines.joined(separator: "\n"))
        Output:
        """
    }

    public func cached(_ lines: [String]) -> [String]? { cache[Self.key(lines)] }

    /// Corrected lines from the model, or the gated input when the model is
    /// unavailable, slow or unsure. Never returns nonsense the gate rejected.
    public func verify(_ lines: [String], router: ReasoningRouting?) async -> [String] {
        let gated = Self.gate(lines)
        guard !gated.isEmpty else { return [] }
        let key = Self.key(gated)
        if let hit = cache[key] { return hit }
        guard let router else { return gated }
        let outcome = await router.resolve(ReasoningQuery(question: Self.question(gated), detections: [], localConfidence: 0,
                                                          maxWords: max(12, gated.joined(separator: " ").split(separator: " ").count * 2 + 4), timeout: timeout, raw: true))
        guard outcome.source == .cloud else { return gated }
        let result = Self.parse(outcome.answer, fallback: gated)
        remember(key, result)
        return result
    }

    /// Model output -> lines. "NONE" means nothing real; anything that fails
    /// the gate is dropped even if the model kept it.
    public static func parse(_ answer: String, fallback: [String]) -> [String] {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.uppercased() == "NONE" || t.isEmpty { return [] }
        let lines = t.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" }
        let kept = gate(lines)
        // A model that rambles (more lines than it was given, or a sentence about the task) is ignored.
        return kept.isEmpty || kept.count > fallback.count + 1 ? fallback : kept
    }

    private func remember(_ key: String, _ value: [String]) {
        if cache[key] == nil, cache.count >= cacheCapacity, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        cache[key] = value
        order.removeAll { $0 == key }
        order.append(key)
    }

    static func key(_ lines: [String]) -> String { lines.joined(separator: "\n").lowercased() }
}
