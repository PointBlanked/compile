// Owner: Maxwell's agent, extended for the demo (Bryan). The slow half of a
// slow-fast pair. Every several seconds one frame goes to the reasoning
// models: the vision model describes it in prose, the text model turns the
// prose into fixed fields. The result is the *reference* the fast on-device
// loop consults on every frame: colours come from here (pixel sampling was
// unreliable), detections the reference contradicts are held back, and the
// kind of place is spoken.
//
//   place: kitchen counter
//   objects: red kettle (left); white microwave (centre); blue mug (right)
//   text: none            <- ignored: on-device OCR owns text
//   hazard: hot kettle

import Foundation
import EchoGuideContracts

public struct SceneReference: Sendable, Equatable {
    public struct Object: Sendable, Equatable {
        public var name: String
        public var color: String?
        /// "left", "centre", "right" or nil.
        public var position: String?
    }

    public var place: String?
    public var objects: [Object]
    public var hazard: String?
    public var at: TimeInterval

    public init(place: String? = nil, objects: [Object] = [], hazard: String? = nil, at: TimeInterval) {
        self.place = place
        self.objects = objects
        self.hazard = hazard
        self.at = at
    }

    // MARK: - Prompts

    public static let describePrompt = """
    Describe this photo for a blind person in two or three plain sentences: what kind of place it is, the main \
    things with their colours and whether each is on the left, in the centre or on the right, and anything hazardous. \
    Do not read text aloud.
    """

    public static func structurePrompt(_ prose: String) -> String {
        """
        Convert this scene description into exactly this format and nothing else:
        place: <kind of place, two or three words>
        objects: <colour> <object> (<left|centre|right|unknown>); ... most important first, up to six
        hazard: <one short phrase, or none>

        Description: \(prose)

        Output:
        """
    }

    // MARK: - Parsing

    static let colours: Set<String> = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "brown", "black", "white", "grey", "gray", "teal", "beige", "silver", "gold", "dark", "light"]

    public static func parse(_ text: String, at: TimeInterval) -> SceneReference? {
        var ref = SceneReference(at: at)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "place":
                ref.place = value.isEmpty || value.lowercased() == "none" ? nil : value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            case "objects":
                ref.objects = value.split(separator: ";").compactMap { parseObject(String($0)) }
            case "hazard":
                let v = value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                ref.hazard = v.isEmpty || v == "none" || v.hasPrefix("no ") ? nil : v
            default: continue
            }
        }
        return ref.place == nil && ref.objects.isEmpty ? nil : ref
    }

    static func parseObject(_ raw: String) -> Object? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var position: String?
        if let open = s.lastIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            let p = s[s.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
            position = ["left", "centre", "center", "right"].contains(p) ? (p == "center" ? "centre" : p) : nil
            s = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let stop: Set<String> = ["and", "a", "an", "the"]
        var words: [String] = []
        for w in s.lowercased().split(separator: " ") where !stop.contains(String(w)) { words.append(String(w)) }
        guard !words.isEmpty else { return nil }
        var colourWords: [String] = []
        while let first = words.first, colours.contains(first) {
            colourWords.append(first == "gray" ? "grey" : first)
            words.removeFirst()
        }
        guard !words.isEmpty else { return nil }
        let colour: String? = colourWords.first { $0 != "dark" && $0 != "light" }
        return Object(name: words.joined(separator: " "), color: colour, position: position)
    }

    // MARK: - Lookup

    static let synonyms: [String: [String]] = [
        "cell phone": ["phone", "smartphone", "mobile"], "tv": ["television", "tv screen", "monitor"], "couch": ["sofa"],
        "dining table": ["table", "desk"], "cup": ["mug", "glass"], "potted plant": ["plant"], "laptop": ["computer", "notebook"],
        "remote": ["remote control"], "backpack": ["bag", "rucksack"], "handbag": ["bag", "purse"], "bicycle": ["bike"],
        "person": ["man", "woman", "people", "someone", "child", "boy", "girl"], "chair": ["seat", "stool"], "bottle": ["water bottle"],
        "refrigerator": ["fridge"], "oven": ["stove", "cooker"], "microwave": ["microwave oven"], "keyboard": ["computer keyboard"],
    ]

    func object(for label: String) -> Object? {
        let l = label.lowercased()
        let names = [l] + (Self.synonyms[l] ?? [])
        return objects.first { o in names.contains { o.name == $0 || o.name.hasSuffix(" " + $0) || $0.hasSuffix(" " + o.name) } }
    }

    public func colour(for label: String) -> String? { object(for: label)?.color }
    public func mentions(_ label: String) -> Bool { object(for: label) != nil }

    /// What the agent says when the reference changes: "Kitchen counter. A red kettle on your left, a white microwave ahead."
    public var spokenLine: String {
        var parts: [String] = []
        if let place { parts.append(place.capitalizedFirstLetter + ".") }
        let things = objects.prefix(3).map { o -> String in
            let name = SceneVocabulary.article(o.color.map { "\($0) \(o.name)" } ?? o.name)
            switch o.position {
            case "left": return "\(name) on your left"
            case "right": return "\(name) on your right"
            case "centre": return "\(name) ahead"
            default: return name
            }
        }
        if !things.isEmpty { parts.append((things.joined(separator: ", ") + ".").capitalizedFirstLetter) }
        if let hazard { parts.append("Careful: \(hazard).") }
        return parts.joined(separator: " ")
    }

    /// Same place and same first three objects: nothing new to say.
    public func sameScene(as other: SceneReference) -> Bool {
        place == other.place && objects.prefix(3).map(\.name) == other.objects.prefix(3).map(\.name)
    }
}

/// How the fast loop uses the reference on every frame.
public enum ReferenceFusion {
    /// Colours from the reference; detections the reference contradicts are
    /// dropped when they are not confident. A stale reference does nothing.
    public static func apply(_ reference: SceneReference?, to detections: [Detection], now: TimeInterval,
                             maxAge: TimeInterval = 20, trustAbove: Float = 0.7) -> [Detection] {
        guard let ref = reference, now - ref.at <= maxAge else { return detections.map { var d = $0; if d.kind == .object { d.color = nil }; return d } }
        return detections.compactMap { d in
            guard d.kind == .object, !SceneVocabulary.silent.contains(d.label) else { return d }
            var d = d
            if let o = ref.object(for: d.label) {
                d.color = o.color
                return d
            }
            d.color = nil
            // The reasoning model saw a scene with several things and this was not one of them.
            if ref.objects.count >= 2, d.confidence < trustAbove { return nil }
            return d
        }
    }
}
