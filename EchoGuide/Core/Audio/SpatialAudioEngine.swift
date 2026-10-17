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
    private var started = false

    public init() {}

    private func startIfNeeded() {
        guard !started else { return }
        engine.attach(environment)
        engine.attach(player)
        // Mono source into the environment node is what makes it positional.
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .auto
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        pingBuffer = Self.makePing(format: format)
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

    public func ping(azimuth: Float, elevation: Float) async {
        startIfNeeded()
        guard started, let pingBuffer else { return }
        let p = SpatialAudioMath.position(azimuth: azimuth, elevation: elevation)
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
        player.scheduleBuffer(pingBuffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    public func speak(_ text: String, azimuth: Float) async {
        // Spoken words carry the instruction; a ping first gives the direction.
        await ping(azimuth: azimuth, elevation: 0)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.prefersAssistiveTechnologySettings = true
        synth.speak(u)
    }

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
