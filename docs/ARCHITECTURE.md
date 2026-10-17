# Architecture

EchoGuide is a set of independent engines that only share the types in [`Contracts.swift`](../EchoGuide/Core/Contracts/Contracts.swift), composed in one place, [`AppRuntime.swift`](../EchoGuideApp/Sources/AppRuntime.swift). This document covers how data flows through them, how latency is kept bounded, and the rules that keep the product safe and quiet.

## 1. Data flow

```mermaid
sequenceDiagram
    participant C as Camera (ARKit/AVCapture queue)
    participant G as FrameDeltaEngine
    participant P as PerceptionPipeline
    participant V as LocalVisionEngine (actor)
    participant F as SpatialFence
    participant A as AgentCore (actor)
    participant M as AutomationEngine (actor)
    participant O as Audio / Haptics

    C->>P: submit(frame) 30–60 fps
    P->>G: analyze luma (~3 µs)
    alt nothing changed
        G-->>P: skip (most frames)
    else motion, forced, or idle refresh
        P->>V: infer (one in flight; extra frames dropped)
        V-->>P: detections (objects, fingertip, text, barcodes)
        P->>F: evaluate (per-zone LiDAR depth)
        P->>A: ingest(result, fence)
        alt Explore / Read
            A->>O: one sentence or a warning, paced
        else Find
            A-->>P: hand to automation
            P->>M: ingest(result, fence)
            M->>O: haptic pulse / direction / confirm
        end
    end
```

## 2. Latency and back-pressure

| Stage | Budget | Mechanism |
|---|---|---|
| Motion gate | < 0.1 ms | A 32×24 grid of luma samples; a global mean shift is removed so auto-exposure isn't counted as motion ([`FrameDeltaEngine`](../EchoGuide/Core/Camera/FrameDeltaEngine.swift)) |
| Vision | < 12 ms | One Vision request handler per frame. Object model on the Neural Engine (`.cpuAndNeuralEngine`); OCR and barcodes on a per-mode schedule (every frame in Read, every 3rd in Explore) |
| Decision | < 0.05 ms | Narrator and automation are plain state machines; no model in the decision loop |
| Cue | < 300 ms | Haptics are immediate; speech starts with a directional ping |
| Cloud | 2.5 s (6 s for Describe) | A hard deadline, after which the local answer is spoken |

**One inference in flight.** `PerceptionPipeline` sets a busy flag under a lock on the camera queue. A frame that arrives while the model is busy is dropped, never queued, so a slow frame can't push every later cue back. If the dropped frame had motion in it, the next frame is forced through, so the motion is not lost.

**Per-mode schedule.** Read re-checks a still page every 0.5 s and runs OCR on every frame. Explore re-checks a still scene every 1 s, so something that moved in slowly is still seen. Find relies on motion, because the hand is moving.

Measured numbers are in [`benchmarks/results`](../benchmarks/results); reproduce them with `swift run -c release EchoGuideBench`.

## 3. Coordinates

Everything downstream of vision uses one convention: **upright portrait image space, origin top-left, x to the user's right, y down, both 0–1.**
- Vision returns boxes with a bottom-left origin; `VisionGeometry` converts them once.
- The LiDAR depth map is in landscape sensor space; `DepthSampler.sensorPoint(fromUpright:)` maps back to it.
- Depth reads use a confidence-filtered 3×3 median, so one noisy pixel never moves a cue.

## 4. The agent ([`AgentCore`](../EchoGuide/Core/Agent/AgentCore.swift))

| Mode | Owner of speech | Policy |
|---|---|---|
| Explore | `SceneNarrator` | Settled across 2+ frames; one name per label per 20 s; text per 45 s; 2.5 s between sentences; an obstacle closer than 1.2 m straight ahead interrupts and buzzes |
| Read | `TextReader` | Rows grouped by vertical overlap, then sorted left to right; OCR noise stripped; a line is not repeated for 60 s |
| Describe | Router, then `SceneSummary` | Multimodal model with the photo (consent required), at most 40 words, most important first, positions included; otherwise an on-device grouped summary ("Ahead: …. On your left: …. Text: …") |
| Find | `AutomationEngine` | See section 5 |

Speech pacing is shared. The agent estimates how long each sentence takes (about 2.5 words a second), so routine lines wait their turn, while urgent ones (obstacles, hazards) always go first.

## 5. Find: guidance and action ([`AutomationEngine`](../EchoGuide/Core/Automation/AutomationEngine.swift), Bryan)

`scanning → guiding → onTarget → completed → scanning`

- [`CognitiveTaskIsolation`](../EchoGuide/Core/Cognitive/CognitiveTaskIsolation.swift) reduces all detections to **one** target:
  - scored by goal match, closeness to the fingertip, size and confidence
  - sticky: a rival must score 1.35× higher to replace the current target
  - settled: it must appear on several frames first
  - phrased with one direction at a time ("Move left a little")
- **Haptics:** pulse rate rises from 1.6 to 12 Hz as the finger closes in, sharpness encodes up or down, and a spatial-audio ping carries left or right, since a phone has a single actuator. Inside the alignment tolerance, a double tap plays and the pulses stop.
- **Dwell to act:** holding on target for 0.8 s is the confirmation. Only then is a plugin tool called. Physical tools (the microwave, a lock) are never called without it.
- **Lost target:** the last cue is kept for 1.2 s, then haptics stop. The engine never confirms against a remembered box.
- **Completed targets** are excluded for 8 s, so "done" moves on instead of guiding back to the same button.

## 6. Hazard fence ([`DigitalFenceEngine`](../EchoGuide/Core/Fence/DigitalFenceEngine.swift), Bryan)

- Zones follow a detected label ("oven", "knife") or cover a fixed region of the frame, and can be configured per home in JSON (`FenceConfig`).
- The fingertip inside a zone's margin gives *Careful*; inside the zone gives *Stop*, which preempts all guidance and cancels any dwell in progress.
- With LiDAR, the hand and each zone are depth-sampled separately. A hand that overlaps a zone on screen but is 80 cm in front of it counts as an approach, not a breach.

## 7. Cloud routing ([`CloudReasoningRouter`](../EchoGuide/Core/Router/CloudReasoningRouter.swift))

```
local confidence ≥ 0.85            → local answer, no network
offline / no provider / cap hit    → local fallback (tagged)
breaker open (3 failures, 60 s)    → local fallback
otherwise                          → provider under a hard deadline; empty or late → local
```

- Providers (Gemini `generateContent`, OpenAI Chat Completions) talk only to the proxy.
- The prompt's length scales with the request: 8 words for a step, 40 for a scene.

## 8. Tools (MCP, [`PluginRegistry`](../EchoGuide/Core/Plugins/PluginRegistry.swift))

- Each tool declares what it claims (labels, words in recognised text, barcode prefixes) and its side effect (`none`, `reversible` or `physical`).
- The registry serves MCP `initialize`, `tools/list` and `tools/call` over JSON-RPC 2.0, and imports tools from remote MCP servers over Streamable HTTP. Remote tools default to `physical`, the most cautious setting.
- Built-in tools are never shadowed by a remote tool with the same name.
- A per-home `PluginManifest` names secrets without containing them; the app resolves them from the Keychain.

## 9. Proxy ([`proxy/server.mjs`](../proxy/server.mjs))

- Device bearer tokens are compared in constant time against SHA-256 hashes.
- Each device gets a token-bucket rate limit, and the proxy enforces a model allow-list, output-token caps, a 2 MB body cap and a 10 s upstream timeout.
- Speech-to-text gets a 30-second Deepgram token, so the phone opens the WebSocket directly.
- Text-to-speech is streamed back chunk by chunk.

## 10. Testing

- 112 Swift tests cover every engine's pure logic: motion gating, the pipeline's back-pressure, geometry, the narrator's pacing and salience, reading order, every automation transition, fence depth rules, router fallbacks and the circuit breaker, MCP JSON-RPC, the plugins against stubbed HTTP, and the trial recorder's CSV.
- CI also compiles the iOS-only code and the full app for the iOS Simulator.
- Hardware behaviour (camera, Neural Engine, LiDAR, actuator) is measured on device with the in-app speed test.
