// Owner: Maxwell. Optional voice layer on top of the hands-free core.
//
//   mic (16 kHz PCM16) --WebSocket--> Deepgram live STT --> transcripts
//   text --HTTP stream--> ElevenLabs TTS (through the proxy) --> PCM chunks
//
// Keys never ship: the proxy mints a 30-second Deepgram token per session and
// forwards TTS. Offline, none of this runs and on-device speech carries on;
// voice is a convenience ("find the start button"), never a requirement.

import Foundation
import EchoGuideContracts

public struct Transcript: Sendable, Equatable {
    public var text: String
    /// Deepgram `is_final`: this segment will not be revised.
    public var isFinal: Bool
    /// Deepgram `speech_final`: the speaker paused; act on it now.
    public var endOfUtterance: Bool
}

/// What a spoken sentence asks for. Deliberately tiny: two intents cover the
/// hands-free product; anything else becomes a question for the router.
public enum VoiceIntent: Sendable, Equatable {
    case find(String)
    case stop
    case question(String)

    public static func parse(_ raw: String) -> VoiceIntent? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !s.isEmpty else { return nil }
        if ["stop", "cancel", "never mind", "nevermind"].contains(s) { return .stop }
        for prefix in ["find the ", "find my ", "find ", "where is the ", "where is my ", "where's the ", "where is ", "show me the "] where s.hasPrefix(prefix) {
            let target = String(s.dropFirst(prefix.count))
            if !target.isEmpty { return .find(target) }
        }
        return .question(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum DeepgramMessage {
    /// Parses one Deepgram live `Results` message; nil for metadata/keepalive.
    static func transcript(from data: Data) -> Transcript? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["type"] as? String == "Results",
              let channel = json["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let text = alts.first?["transcript"] as? String, !text.isEmpty else { return nil }
        return Transcript(text: text, isFinal: json["is_final"] as? Bool ?? false, endOfUtterance: json["speech_final"] as? Bool ?? false)
    }
}

public actor DeepgramSTTClient {
    private let proxyBase: URL
    private let transport: HTTPTransport
    private let deviceToken: @Sendable () async -> String?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?

    public init(proxyBase: URL, transport: HTTPTransport = URLSessionTransport(), session: URLSession = .shared,
                deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.transport = transport
        self.session = session
        self.deviceToken = deviceToken
    }

    /// Opens a live session. Feed audio with `send(_:)`; read from the stream.
    public func start(model: String = "nova-3", language: String = "en") async throws -> AsyncThrowingStream<Transcript, Error> {
        let grant = try await transport.postJSON(proxyBase.appendingPathComponent("v1/voice/stt-token"), body: [:], bearer: await deviceToken())
        guard let token = grant["access_token"] as? String else { throw URLError(.userAuthenticationRequired) }

        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            .init(name: "model", value: model), .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"), .init(name: "sample_rate", value: "16000"), .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"), .init(name: "endpointing", value: "300"), .init(name: "smart_format", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        socket = ws
        ws.resume()

        // Deepgram closes idle sockets after ~10 s without audio.
        keepAlive = Task { [weak ws] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                try? await ws?.send(.string(#"{"type":"KeepAlive"}"#))
            }
        }

        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while true {
                        let message = try await ws.receive()
                        let data: Data
                        switch message {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        if let t = DeepgramMessage.transcript(from: data) { continuation.yield(t) }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// 16 kHz mono little-endian PCM16.
    public func send(_ pcm: Data) async throws {
        try await socket?.send(.data(pcm))
    }

    public func stop() async {
        keepAlive?.cancel()
        try? await socket?.send(.string(#"{"type":"CloseStream"}"#))
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}

public struct ElevenLabsTTSClient: Sendable {
    public var proxyBase: URL
    public var voiceID: String
    public var session: URLSession
    public var deviceToken: @Sendable () async -> String?

    public init(proxyBase: URL, voiceID: String, session: URLSession = .shared, deviceToken: @escaping @Sendable () async -> String?) {
        self.proxyBase = proxyBase
        self.voiceID = voiceID
        self.session = session
        self.deviceToken = deviceToken
    }

    /// Streams 16 kHz mono PCM16 in chunks as they arrive, so playback starts
    /// on the first chunk rather than after the whole sentence.
    public func speak(_ text: String, chunkBytes: Int = 3200, onChunk: @Sendable (Data) async -> Void) async throws {
        var req = URLRequest(url: proxyBase.appendingPathComponent("v1/voice/tts"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await deviceToken() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice_id": voiceID])

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var buffer = Data()
        buffer.reserveCapacity(chunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkBytes {
                await onChunk(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { await onChunk(buffer) }
    }
}

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Microphone -> 16 kHz mono PCM16 for Deepgram, plus a streaming PCM player
/// for ElevenLabs. Shares the app's AVAudioSession; does not change category.
public final class VoiceAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
    }

    public func startCapture(onAudio: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: pcm16k)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = 16_000 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.pcm16k, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            onAudio(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
        if !engine.isRunning { try engine.start() }
        player.play()
    }

    public func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Queue one PCM16 chunk from ElevenLabs for gapless playback.
    public func play(pcm16 chunk: Data) {
        let frames = chunk.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        chunk.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        if !engine.isRunning { try? engine.start(); player.play() }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
#endif
