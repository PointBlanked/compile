# Freestyle deploy (demo backend)

Two VMs, each published on a free `style.dev` domain. Freestyle is a workbench,
not production hosting: fine for the hackathon, move the proxy to a real host
before any public release.

| Script | VM | Image | Port | Gives the app |
|---|---|---|---|---|
| `deploy-proxy.sh` | `echoguide-proxy` | `freestyle/ubuntu-sm` | 8787 | `EGProxyBaseURL` for the router and Maxwell's voice loop |
| `deploy-kokoro.sh` | `echoguide-voice` | `freestyle/ubuntu`, resized to 8 vCPU / 16 GiB | 8880 | `KokoroSpeechProvider(baseURL:)` |

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

Cost: the voice VM is 8 vCPU / 16 GiB, about $0.53 per hour awake against the
team's credits. Pause it between sessions (`freestyle vm pause echoguide-voice`):
a paused VM bills storage only, and a VM from the snapshot boots with the model
already loaded.
