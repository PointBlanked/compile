# Freestyle deploy (demo backend)

Two VMs, each published on a free `style.dev` domain. Freestyle is a workbench,
not production hosting: fine for the hackathon, move the proxy to a real host
before any public release.

| Script | VM | Image | Port | Gives the app |
|---|---|---|---|---|
| `deploy-proxy.sh` | `echoguide-proxy` | `freestyle/ubuntu-sm` | 8787 | `EGProxyBaseURL` for the router and Maxwell's voice loop |
| `deploy-kokoro.sh` | `echoguide-voice` | `freestyle/ubuntu`, resized to 8 vCPU / 16 GiB | 8880 | `KokoroSpeechProvider(baseURL:)` |
| `deploy-vision.sh` | `echoguide-vision` | `freestyle/ubuntu`, 8 vCPU / 16 GiB | 8080 vision, 8081 text | `visionURL` and `textURL` in `echoguide.json` |

```bash
npx -y freestyle@latest login            # once, interactive
cp infra/freestyle/.env.proxy.example infra/freestyle/.env.proxy   # fill in keys
infra/freestyle/deploy-proxy.sh
infra/freestyle/deploy-kokoro.sh
```

Both scripts are idempotent: re-run to update. Snapshot each VM once it works
(`freestyle snapshot create <slug> --slug <slug>-ok`); a VM from the snapshot
boots in about a second with the Kokoro model already loaded.

## Measured (2026-10-17, from a laptop over the public domain)

| Phrase | 4 vCPU | 8 vCPU |
|---|---|---|
| "Start. Move right." | 1.47 s | 0.77 s |
| "Stop. Hob." | 0.83 s | 0.74 s |
| "Oat milk. Contains oats." | 1.00 s | 0.66 s |
| "Hold still." | | 0.48 s |

Output is 24 kHz 16-bit mono WAV with a streaming header; `KokoroSpeechProvider`
rewrites the RIFF sizes before playback. The provider timeout is 2.5 s; cached
and prewarmed phrases skip the round trip.

Live now: `https://echoguide-voice.style.dev` (snapshot `echoguide-voice-ok`).

## Vision and text models (llama.cpp server, OpenAI-compatible)

Measured from a laptop over the public domain, 512 px photo, 8 vCPU:

| Model | Scene description | OCR correction |
|---|---|---|
| SmolVLM2-500M (serves `https://echoguide-vision.style.dev`) | **3.9 s**, names colours and printed text | rambles, unusable |
| SmolVLM2-2.2B (kept on the VM, port 8080) | 9.7 s | leaves errors |
| Qwen2.5-1.5B-Instruct Q4 (serves `https://echoguide-text.style.dev`) | n/a | **0.4 to 1.6 s**, "EX1T" to "EXIT", "DEFR0ST" to "DEFROST" with the worked-example prompt |

The app asks for a scene line only when the set of things in view turns over
(see `SceneIntelligence`), so the 3.9 s never blocks perception; OCR lines
go through the text model off the frame path with a 2.5 s deadline and a
cache. Snapshot `echoguide-vision-ok` holds all three containers loaded.

Cost: the voice VM is 8 vCPU / 16 GiB, about $0.53 per hour awake against the
team's credits. Pause it between sessions (`freestyle vm pause echoguide-voice`):
a paused VM bills storage only, and a VM from the snapshot boots with the model
already loaded.
