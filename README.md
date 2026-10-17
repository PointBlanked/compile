# AutoVision Audio Engine (EchoGuide)

Hands-free spatial vision for people with visual impairment or dementia. The camera watches. When something changes, the engine works out the **one** next step and guides the hand there with haptic pulses and directional audio. It calls a tool only when the user holds their finger on the target. The phone screen is optional.

* NOT A MEDICAL DEVICE OR FDA APPROVED CURRENTLY JUST FOR TESTING

```
camera ─► FrameDeltaEngine ─► LocalVisionEngine ─► DigitalFence ─┐
 (ARKit or AVCapture)  skip ~99% static     YOLO INT8 + hand + OCR       │
                                                                          ▼
                     CloudReasoningRouter ◄── AutomationEngine ◄── CognitiveTaskIsolation
                     (only < 85% conf)          │ state machine       one step only
                     PluginRegistry (MCP) ◄─────┤
                                                ├─► SpatialHapticEngine (CoreHaptics)
                                                └─► SpatialAudioEngine (AVAudioEngine 3D)
```

## Team and ownership

Two owners. Engines meet only through `EchoGuideContracts`, so the two never edit the same file. Ownership is enforced in `.github/CODEOWNERS`.

| Owner | Area | Paths | Files |
|---|---|---|---|
| Maxwell | Perception + infrastructure: what the phone senses, and the plumbing | `EchoGuide/Core/Camera/`, `Vision/`, `Depth/`, `Plugins/`, `Router/`, `.github/`, `EchoGuideTests/`, `Package.swift`, `plugins/` | `FrameDeltaEngine`, `CameraFeed`, `LocalVisionEngine`, `LiDARDepthEngine`, `PluginRegistry`, `CloudReasoningRouter`, CI, tests |
| Bryan | Experience + safety: everything the user feels, hears and sees | `EchoGuide/Core/Fence/`, `Haptics/`, `Audio/`, `Automation/`, `Cognitive/`, `EchoGuide/UI/` | `DigitalFenceEngine`, `SpatialHapticEngine`, `SpatialAudioEngine`, `AutomationEngine`, `CognitiveTaskIsolation`, `GuidanceView` |
| Both | Shared contracts | `EchoGuide/Core/Contracts/` | `Contracts.swift` (needs both approvals) |

The split follows the pipeline: Maxwell owns everything up to "a detection with a confidence and a depth"; Bryan owns everything from "what one step does the user take, and how do they feel it".

### Branches

`feature/maxwell-vision`, `feature/maxwell-plugins`, `feature/bryan-automation`, `feature/bryan-haptics`, `feature/bryan-fence`. Each branch opens a PR into `main`. CI must pass and the owner of every path the PR touches must approve.

## Digital fence (Bryan)

There are two layers. Each one only reports a `FenceEvent`, and `AutomationEngine` decides how the user hears or feels it.

- **Spatial fence:** hazard zones the camera can see, such as the hob or a knife. A zone follows a detected label or covers a fixed part of the frame. When the fingertip comes near a zone, the user gets "Careful" and a warning pulse. When it enters the zone, they get "Stop" and the warning preempts all other guidance. If LiDAR is available, its depth reading rules out cases where the hand only overlaps the zone on screen but is not near it.
- **Location fence:** safe areas for dementia wandering. A position must stay outside the area for 45 s before it counts as leaving, and fixes with poor accuracy are ignored. The event is reported once, and a `notify_caregiver` MCP tool is called if one is registered.

## Targets

| Metric | Target | Where it is measured |
|---|---|---|
| Frame-delta analysis | < 1 ms p50, < 3 ms p95 (CI debug build) | `FrameDeltaTests.benchmarkUnderBudget` |
| Local inference (object + hand) | < 12 ms on A17-class | `LocalVisionEngine.p95Ms`, on device |
| Local end-to-end (frame to haptic) | < 15 ms | on device |
| Audio / haptic cue | < 300 ms | on device |
| Static frames skipped | ~99% in a still scene | `FrameDeltaStats.skipRatio` |
| Edge compute share | > 95% of resolutions local | `ReasoningOutcome.source` |
| Airplane Mode | 100% working, local fallback | `RouterTests.airplaneModeFallsBackLocally` |

Read these honestly:

- **OCR does not fit inside 12 ms.** `VNRecognizeTextRequest` at `.fast` takes roughly 10 to 35 ms, so it runs on every third inferred frame (`ocrEveryNthFrame`). Only object detection and the hand fit inside the 12 ms budget.
- **The cloud path cannot meet 15 ms.** A cloud round trip is hundreds of milliseconds. The < 15 ms target covers only the local path, and the router gives the cloud a hard 2.5 s timeout.
- **"100% Airplane Mode" and "cloud below 85%" conflict, by design.** When the device is offline, low-confidence steps get the best local answer. The response is tagged `localFallback` so telemetry shows how often the cloud was missed.

## Build

```bash
swift build && swift test        # macOS host: pure logic, 36 tests
```

The iOS-only paths (ARKit, the camera, the haptic actuator) are behind `#if canImport(...) && os(iOS)`. The `ios-build` CI job compiles them with `xcodebuild` for the iOS Simulator. Real latency numbers need a device.

### What the app target has to supply

This package is the engine. An Xcode iOS app target links the `EchoGuide` library and does the following:

1. Bundles a YOLO Core ML model and passes it to `LocalVisionEngine(modelURL:)`. Export it with `yolo export model=yolo11n.pt format=coreml int8=True nms=True`. Models are git-ignored.
2. Sets up the camera feed. With LiDAR, it runs `LiDARDepthEngine` and feeds its `onFrame` into `FrameDeltaEngine`. ARKit owns the camera, so `CameraFeed` cannot run at the same time. Without LiDAR, it uses `CameraFeed`.
3. Builds a `PerceptionPipeline(vision: LocalVisionEngine(...))` and calls `submit` from the camera queue. The pipeline skips static frames, keeps at most one inference in flight (frames that arrive while it is busy are dropped, not queued), and times every stage. In `onResult`, run `SpatialFence.evaluate`, then `AutomationEngine.ingest(_:fence:)`.
4. Adds `Info.plist` keys: `NSCameraUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription`, plus the `location` background mode for the location fence.
5. Points `GeminiProvider` / `OpenAIProvider` at a proxy you run. No API keys ship in the app.

## Plugins (MCP)

Built-in tools: **Home Assistant** (presses the control for the user through one hub that already integrates thousands of appliances), **caregiver alerts** (signed webhook, idempotent, saved to a disk outbox so an alert raised offline is delivered on reconnect; the user is told "your carer has been told" only once it has actually gone out), and **product lookup** (barcode to product name and allergens via Open Food Facts; QR codes never leave the device). A per-home `PluginManifest` JSON sets all of this up without a code change, and secrets come from the Keychain, never from the manifest.

`PluginRegistry` serves MCP `initialize`, `tools/list` and `tools/call` over JSON-RPC 2.0. `MCPHTTPClient` connects to remote MCP servers over Streamable HTTP. An example FastMCP server is in `plugins/smart_home_server.py`.

Remote tools are registered as `physical` unless told otherwise. A physical tool runs only after the user holds their finger on the target (0.8 s dwell).

## Not built yet

- The WebSocket voice loop (Deepgram STT / ElevenLabs TTS). On-device `AVSpeechSynthesizer` is used for now, so the app works offline.
- The OpenAI Realtime API (multi-turn). The router uses one-shot Chat Completions.
- The Xcode app target and the bundled model.
