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
| Maxwell | Perception + infrastructure: what the phone senses, and the plumbing | `EchoGuide/Core/Camera/`, `Vision/`, `Depth/`, `Plugins/`, `Router/`, `EchoGuideApp/`, `proxy/`, `.github/`, `EchoGuideTests/`, `Package.swift`, `plugins/` | `FrameDeltaEngine`, `PerceptionPipeline`, `CameraFeed`, `LocalVisionEngine`, `LiDARDepthEngine`, `PluginRegistry`, built-in plugins, `CloudReasoningRouter`, `VoiceLoop`, the iOS app, the key proxy, CI/CD, tests |
| Bryan | Experience + safety: everything the user feels, hears and sees | `EchoGuide/Core/Fence/`, `Haptics/`, `Audio/`, `Automation/`, `Cognitive/`, `EchoGuide/UI/` | `DigitalFenceEngine`, `SpatialHapticEngine`, `SpatialAudioEngine`, `AutomationEngine`, `CognitiveTaskIsolation`, `GuidanceView` |
| Both | Shared contracts | `EchoGuide/Core/Contracts/` | `Contracts.swift` (needs both approvals) |

The split follows the pipeline: Maxwell owns everything up to "a detection with a confidence and a depth"; Bryan owns everything from "what one step does the user take, and how do they feel it".

### Branches

`feature/maxwell-vision`, `feature/maxwell-plugins`, `feature/bryan-automation`, `feature/bryan-haptics`, `feature/bryan-fence`. Each branch opens a PR into `main`. CI must pass and the owner of every path the PR touches must approve.

## Digital fence (Bryan)

There are two layers. Each one only reports a `FenceEvent`, and `AutomationEngine` decides how the user hears or feels it.

- **Spatial fence:** hazard zones the camera can see, such as the hob or a knife. A zone follows a detected label or covers a fixed part of the frame. When the fingertip comes near a zone, the user gets "Careful" and a warning pulse. When it enters the zone, they get "Stop", the warning preempts all other guidance, and any dwell in progress is cancelled so a physical tool cannot fire straight after a hazard. If LiDAR is available, `SpatialFence.evaluate(_:depth:)` samples the hand and the centre of every zone through `DepthProviding`, so a hob at 1.2 m and a knife at 0.4 m each get their own distance; a hand that only overlaps a zone on screen is an approach, not a breach.
- **Location fence:** safe areas for dementia wandering. A position must stay outside the area for 45 s before it counts as leaving, and fixes with poor accuracy are ignored. The event is reported once, and a `notify_caregiver` MCP tool is called if one is registered. The engine enters `outsideSafeArea`, which camera frames do not clear; only `returnedToSafeArea` does, and a paused engine stays paused.

## Automation (Bryan)

`AutomationEngine` runs `scanning -> guiding -> onTarget -> completed -> scanning`. Details that matter for the demo:

- A target that drops out of the frame keeps its last haptic cue for `lostTargetTimeout` (1.2 s), then haptics stop and the engine goes back to scanning. It never announces, confirms or completes against a remembered box.
- A finished target is excluded for `completedCooldown` (8 s), so "done" moves on to the next step instead of guiding the finger back to the same button.
- On target, the guidance pulse train stops and a double tap plays once; hovering does not buzz.
- `GuidanceView` shows the step huge and yellow on black, a second line for carers ("Hold still", "Follow the pulses"), a goal field, and one big Pause/Resume button.

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
swift build && swift test        # macOS host: pure logic, 69 tests (plus `cd proxy && node --test`: 6)
```

The iOS-only paths (ARKit, the camera, the haptic actuator) are behind `#if canImport(...) && os(iOS)`. The `ios-build` CI job compiles them with `xcodebuild` for the iOS Simulator. Real latency numbers need a device.

### The iOS app (`EchoGuideApp/`)

Open `EchoGuideApp/EchoGuideApp.xcodeproj` in Xcode 16+, set your team, and run it on an iPhone. `AppRuntime.swift` is the only place every engine is built and connected:

- With LiDAR, ARKit owns the camera and `LiDARDepthEngine` feeds the pipeline. Without LiDAR, `CameraFeed` does.
- `PerceptionPipeline` → `SpatialFence` → `AutomationEngine` → haptics, audio, plugins and router.
- The location fence, the caregiver outbox flush (every 30 s when online) and the optional voice loop start here too.

Per-home setup goes in `Application Support/echoguide.json` (plugins, safe areas, starting goal); the bundled `echoguide.sample.json` is the fallback. Secrets (the proxy `device_token`, Home Assistant token, webhook signing key) are read from the Keychain, service `EchoGuide`.

**Model:** run the `export-model` workflow (Actions tab), download the `.mlpackage`, and drop it in `EchoGuideApp/Resources/Models/`. It is compiled on first launch. Without it, the app runs hands, text and barcodes only.

> **License:** Ultralytics YOLO (v8 and 11) is **AGPL-3.0**. Shipping it in a closed-source app requires an Ultralytics Enterprise license, or a switch to a permissively licensed detector. Decide this before any public release.

**On-device benchmark:** enable the `-benchmark` launch argument in the scheme, point the phone at a scene with some movement for 20 s, and read the result on screen. The full JSON is in Documents (visible in the Files app). This is how the < 15 ms local target is checked for real.

**TestFlight:** the `ios-release` workflow (manual) archives with cloud signing and uploads. It needs four repo secrets, listed at the top of `.github/workflows/ios-release.yml`.

## Cloud proxy (`proxy/`)

The only place the Gemini, OpenAI, Deepgram and ElevenLabs keys live. It is zero-dependency Node 20+ (`node server.mjs`, tests with `node --test`).

- Devices send `Authorization: Bearer <device token>`. The proxy stores only SHA-256 hashes of allowed tokens (`DEVICE_TOKEN_SHA256S`).
- Per-device rate limit (default 30 per minute), model allow-list, output capped at 120 tokens, 2 MB body cap, 10 s upstream timeout.
- `/v1/voice/stt-token` mints a 30-second Deepgram token, so the phone opens the speech WebSocket directly and the long-lived key never leaves the server. `/v1/voice/tts` streams ElevenLabs audio back as it arrives.
- Deploy it anywhere that runs Node (Fly, Render, Railway, a small VM) and set `EG_PROXY_BASE_URL` for the app build.

## Voice (optional)

Off by default; the product works without it. With voice on (the `voiceEnabled` setting plus a proxy), Deepgram live speech-to-text understands "find the start button" (narrows guidance to that target), "stop", and any other sentence as a question for the router. ElevenLabs streaming TTS is available through the proxy; on-device speech remains the default so everything works offline.

## Plugins (MCP)

Built-in tools: **Home Assistant** (presses the control for the user through one hub that already integrates thousands of appliances), **caregiver alerts** (signed webhook, idempotent, saved to a disk outbox so an alert raised offline is delivered on reconnect; the user is told "your carer has been told" only once it has actually gone out), and **product lookup** (barcode to product name and allergens via Open Food Facts; QR codes never leave the device). A per-home `PluginManifest` JSON sets all of this up without a code change, and secrets come from the Keychain, never from the manifest.

`PluginRegistry` serves MCP `initialize`, `tools/list` and `tools/call` over JSON-RPC 2.0. `MCPHTTPClient` connects to remote MCP servers over Streamable HTTP. An example FastMCP server is in `plugins/smart_home_server.py`.

Remote tools are registered as `physical` unless told otherwise. A physical tool runs only after the user holds their finger on the target (0.8 s dwell).

## Not built yet

- The OpenAI Realtime API (multi-turn). The router uses one-shot Chat Completions.
- A care-provider setup flow that writes `echoguide.json` and the Keychain secrets (today: by hand or MDM).
- Real measurements: run the on-device benchmark on an A17-class iPhone and put the numbers in the targets table.
