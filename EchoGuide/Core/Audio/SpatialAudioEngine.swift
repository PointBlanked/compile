// Owner: Bryan. Directional earcons through AVAudioEngine's environment node
// (HRTF on headphones, equal-power pan on the speaker) plus on-device speech.
// Everything here works in Airplane Mode; cloud TTS is an optional upgrade
// layered on top, never a dependency.

import Foundation
import EchoGuideContracts

public enum SpatialAudioMath {
    /// Azimuth in radians (-π/2 hard left ... +π/2 hard right) from a
    /// horizontal image offset in -1...1.
    public static func azimuth(forOffsetX dx: Float) -> Float {
        max(-1, min(1, dx * 2)) * .pi / 2
    }

    /// Listener-relative position 1 m away for the environment node
    /// (x right, y up, z forward is negative).
    public static func position(azimuth: Float, elevation: Float) -> (x: Float, y: Float, z: Float) {
        (sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation))
    }
}

#if canImport(AVFoundation)
import AVFoundation

public actor SpatialAudioEngine: SpatialAudioCueing {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var pingBuffer: AVAudioPCMBuffer?
    private var wired = false
    private var started = false
    private var observers: [NSObjectProtocol] = []

    private let speech: SpeechSynthesizing?
    private let cache: SpeechCache
    private var speechPlayer: AVAudioPlayer?
    private var speechDelegate: SpeechPlayerDelegate?
    private var urgentUntil: TimeInterval = -.infinity
    /// Where the last phrase came from, for telemetry and tests.
    public private(set) var lastSpeechSource: SpeechSource = .onDevice
    public private(set) var lastSpoken: String?

    /// `speech` is an optional better voice (Kokoro). Without one, or whenever
    /// it fails or is slow, the on-device synthesizer speaks instead.
    public init(speech: SpeechSynthesizing? = nil, cacheCapacity: Int = 64) {
        self.speech = speech
        self.cache = SpeechCache(capacity: cacheCapacity)
    }

    /// Builds the graph once; (re)starts the engine whenever it is down.
    /// A phone call, a route change (headphones out) or backgrounding stops
    /// AVAudioEngine; the next cue brings it back instead of going silent.
    private func startIfNeeded() {
        if !wired {
            engine.attach(environment)
            engine.attach(player)
            // Mono source into the environment node is what makes it positional.
            engine.connect(player, to: environment, format: format)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            player.renderingAlgorithm = .auto
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            pingBuffer = Self.makePing(format: format)
            observeInterruptions()
            wired = true
        }
        guard !started || !engine.isRunning else { return }
        do {
            #if os(iOS)
            let s = AVAudioSession.sharedInstance()
            // Mix with other audio and duck it, so navigation never silences a call app.
            try s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try s.setActive(true)
            #endif
            try engine.start()
            player.play()
            started = true
        } catch {
            started = false
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        var names: [Notification.Name] = [.AVAudioEngineConfigurationChange]
        #if os(iOS)
        names += [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification]
        #endif
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.markStopped() }
            })
        }
    }

    private func markStopped() { started = false }

    public func ping(azimuth: Float, elevation: Float) async {
        startIfNeeded()
        guard started, let pingBuffer else { return }
        let p = SpatialAudioMath.position(azimuth: azimuth, elevation: elevation)
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        schedule(pingBuffer)
    }

    /// Synchronous on purpose: the async `scheduleBuffer` variant would hold
    /// the actor until the buffer has played.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    public func speak(_ text: String, azimuth: Float) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let urgent = SpeechPolicy.isUrgent(text)
        // A routine instruction never talks over a hazard or wandering alert.
        if !urgent, isSpeaking, Date().timeIntervalSince1970 < urgentUntil { return }

        // Spoken words carry the instruction; a ping first gives the direction.
        await ping(azimuth: azimuth, elevation: 0)
        stopSpeaking()
        lastSpoken = text

        if let wav = await synthesized(text) {
            do {
                let p = try AVAudioPlayer(data: wav)
                let d = SpeechPlayerDelegate()
                p.delegate = d
                speechDelegate = d
                speechPlayer = p
                p.prepareToPlay()
                if p.play() {
                    lastSpeechSource = .kokoro
                    if urgent { urgentUntil = Date().timeIntervalSince1970 + p.duration }
                    return
                }
            } catch {}
            speechPlayer = nil
        }

        lastSpeechSource = .onDevice
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.prefersAssistiveTechnologySettings = true
        // ~3 words/s at this rate, generous so the alert is not talked over.
        if urgent { urgentUntil = Date().timeIntervalSince1970 + Double(text.split(separator: " ").count) / 2.5 }
        synth.speak(u)
    }

    public var isSpeaking: Bool { synth.isSpeaking || (speechPlayer?.isPlaying ?? false) }

    private func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        speechPlayer?.stop()
        speechPlayer = nil
    }

    /// Cached or freshly synthesized WAV, nil when there is no provider or it
    /// failed (the caller then uses the on-device voice).
    private func synthesized(_ text: String) async -> Data? {
        guard let speech else { return nil }
        if let hit = await cache.get(text) { return hit }
        guard let wav = try? await speech.synthesize(text) else { return nil }
        await cache.put(text, wav)
        return wav
    }

    /// Synthesize phrases the demo will need ("Hold still", "Stop. Hob.") so
    /// the first time they are spoken is as fast as the second.
    public func prewarm(_ phrases: [String]) async {
        guard speech != nil else { return }
        for p in phrases where await cache.get(p) == nil {
            _ = await synthesized(p)
        }
    }

    public var cachedPhrases: Int {
        get async { await cache.count }
    }

    /// Keeps the player alive until it finishes; AVAudioPlayer needs a delegate
    /// object with a stable lifetime to report completion.
    private final class SpeechPlayerDelegate: NSObject, AVAudioPlayerDelegate {}

    /// 60 ms 1.2 kHz sine with a short fade, cheap to schedule repeatedly.
    private static func makePing(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.06)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        let n = Int(frames)
        for i in 0..<n {
            let t = Float(i) / Float(format.sampleRate)
            let env = min(1, Float(i) / 200) * min(1, Float(n - i) / 400)
            ch[i] = sin(2 * .pi * 1200 * t) * 0.5 * env
        }
        return buf
    }
}
#endif
