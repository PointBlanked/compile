// Owner: Bryan. Pluggable text-to-speech. The default voice is the on-device
// AVSpeechSynthesizer, which always works. An open-weight Kokoro voice can be
// layered on top through any server that speaks the OpenAI audio API, such as
// Kokoro-FastAPI on a laptop or Raspberry Pi in the home:
//
//     docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu:latest
//
// The provider returns a WAV; SpatialAudioEngine plays it and falls back to
// the on-device voice on any error or timeout, so Airplane Mode still works.

import Foundation

/// Produces a playable audio file (WAV) for a short phrase.
public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ text: String) async throws -> Data
}

public enum SpeechProviderError: Error, Equatable {
    case badStatus(Int)
    case emptyAudio
    case timeout
}

/// Kokoro-82M through an OpenAI-compatible `/v1/audio/speech` endpoint.
public struct KokoroSpeechProvider: SpeechSynthesizing {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var baseURL: URL
    /// Kokoro voice id, e.g. "af_heart", "bf_emma", or a blend "af_bella(2)+af_sky(1)".
    public var voice: String
    public var speed: Double
    /// Per-request budget. A spoken cue that arrives late is worse than the
    /// on-device voice arriving now.
    public var timeout: TimeInterval
    private let transport: Transport

    public init(baseURL: URL, voice: String = "af_heart", speed: Double = 1.0, timeout: TimeInterval = 2.5,
                transport: Transport? = nil) {
        self.baseURL = baseURL
        self.voice = voice
        self.speed = speed
        self.timeout = timeout
        self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
    }

    public func request(for text: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": voice,
            "response_format": "wav",
            "speed": speed,
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    public func synthesize(_ text: String) async throws -> Data {
        let (data, response) = try await withTimeout(timeout) { try await transport(request(for: text)) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpeechProviderError.badStatus(http.statusCode)
        }
        guard data.count > 44 else { throw SpeechProviderError.emptyAudio } // a WAV header alone is 44 bytes
        // Kokoro-FastAPI streams its WAV, so the header says "unknown length"
        // (0xFFFFFFFF). AVAudioPlayer wants the real sizes.
        return WAVEncoder.withCorrectSizes(data)
    }
}

/// Runs `body` or throws `SpeechProviderError.timeout`, whichever comes first.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw SpeechProviderError.timeout
        }
        guard let first = try await group.next() else { throw SpeechProviderError.timeout }
        group.cancelAll()
        return first
    }
}

/// Phrases repeat ("Start. Move right.", "Hold still"), so synthesized audio
/// is kept by text. Bounded, least recently used out first.
public actor SpeechCache {
    private var store: [String: Data] = [:]
    private var order: [String] = []
    public let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public var count: Int { store.count }

    public func get(_ text: String) -> Data? {
        guard let d = store[text] else { return nil }
        order.removeAll { $0 == text }
        order.append(text)
        return d
    }

    public func put(_ text: String, _ data: Data) {
        if store[text] == nil, store.count >= capacity, let oldest = order.first {
            order.removeFirst()
            store[oldest] = nil
        }
        store[text] = data
        order.removeAll { $0 == text }
        order.append(text)
    }
}

/// Which phrases may interrupt which. A hazard or wandering alert cuts off
/// anything; a routine instruction never cuts off an alert still playing.
public enum SpeechPolicy {
    public static func isUrgent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("Stop") || t.hasPrefix("Careful") || t.hasPrefix("You have left")
    }
}

public enum SpeechSource: String, Sendable {
    case onDevice
    case kokoro
}

/// Minimal 16-bit mono WAV writer. Lets any raw PCM16 stream (an ElevenLabs
/// stream through the proxy, a Deepgram echo, a test tone) become a
/// `SpeechSynthesizing` result: collect the chunks, wrap, done.
public enum WAVEncoder {
    public static func pcm16Mono(_ samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm16Mono(pcm: pcm, sampleRate: sampleRate)
    }

    /// Rewrites the RIFF and `data` chunk sizes of a complete WAV file whose
    /// header was written before its length was known (streaming servers put
    /// 0xFFFFFFFF or 0 there). Anything that is not a RIFF/WAVE file is
    /// returned untouched.
    public static func withCorrectSizes(_ wav: Data) -> Data {
        guard wav.count >= 12,
              wav[wav.startIndex..<wav.startIndex + 4].elementsEqual("RIFF".utf8),
              wav[wav.startIndex + 8..<wav.startIndex + 12].elementsEqual("WAVE".utf8) else { return wav }
        var d = Data(wav) // rebase indices at 0
        func u32(at i: Int) -> UInt32 {
            UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
        }
        func put(_ v: UInt32, at i: Int) {
            d[i] = UInt8(v & 0xFF); d[i + 1] = UInt8(v >> 8 & 0xFF); d[i + 2] = UInt8(v >> 16 & 0xFF); d[i + 3] = UInt8(v >> 24)
        }
        // Walk the chunks to find "data"; its payload runs to the end of the file.
        var i = 12
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self)
            let size = Int(u32(at: i + 4))
            if id == "data" {
                let actual = d.count - (i + 8)
                if size != actual { put(UInt32(actual), at: i + 4) }
                break
            }
            i += 8 + size + (size & 1)
        }
        let riff = d.count - 8
        if Int(u32(at: 4)) != riff { put(UInt32(riff), at: 4) }
        return d
    }

    /// Wraps little-endian mono PCM16 bytes in a WAV header.
    public static func pcm16Mono(pcm: Data, sampleRate: Int) -> Data {
        var d = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(pcm.count)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(pcm)
        return d
    }
}
