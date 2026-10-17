// Owner: Bryan. Hands-free goal entry for people who cannot see the goal
// field: the user says "find the start button" and the engine narrows to
// "start button". Recognition is on-device (Speech framework) so it works in
// Airplane Mode; nothing leaves the phone.

import Foundation

/// Turns a transcript into the goal words CognitiveTaskIsolation matches on.
public enum GoalPhraseParser {
    static let filler: Set<String> = [
        "find", "where", "is", "wheres", "where's", "show", "me", "press", "push", "touch", "tap", "hit",
        "go", "to", "the", "a", "an", "my", "please", "can", "you", "i", "want", "need", "help", "with",
        "hey", "echo", "guide", "echoguide", "on", "for", "look", "locate", "get", "um", "uh",
    ]

    /// nil when nothing is left after stripping filler ("um, please").
    public static func goal(from transcript: String) -> String? {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty && !filler.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}

#if canImport(Speech) && os(iOS)
import Speech
import AVFoundation

/// One short listening window: tap the mic, say the goal, done.
public final class VoiceGoalListener: @unchecked Sendable {
    public enum ListenError: Error { case notAuthorized, unavailable }

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    /// Stop listening after this long even if the user is still talking.
    public var window: TimeInterval = 5

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Returns the parsed goal, or nil when nothing usable was said.
    public func listen() async throws -> String? {
        guard let recognizer, recognizer.isAvailable else { throw ListenError.unavailable }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw ListenError.notAuthorized }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        defer {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            // Give the speaker back to the guidance voice.
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        }

        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        let transcript: String = await withCheckedContinuation { c in
            var done = false
            var best = ""
            var task: SFSpeechRecognitionTask?
            let finish = {
                guard !done else { return }
                done = true
                task?.cancel()
                c.resume(returning: best)
            }
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result { best = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { finish() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + window) {
                request.endAudio()
                finish()
            }
        }
        return GoalPhraseParser.goal(from: transcript)
    }
}
#endif
