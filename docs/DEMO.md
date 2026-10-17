# EchoGuide: the 90-second demo

Two people. **Tester** wears a blindfold and holds the phone at chest height,
camera out, with the speaker up (or one AirPod). **Narrator** holds the mic,
says one sentence per beat, and never touches the tester. The screen is
mirrored to the projector (QuickTime > New Movie Recording > iPhone, or
AirPlay), so the room sees what the AI sees: boxes, the fingertip, the one
target, the dwell ring.

The story in one line: **every assistant today waits to be asked. EchoGuide
acts, and it closes the last 10 cm.**

## Room setup (10 minutes before)

| Thing | Why |
|---|---|
| A table 4 m from the start mark, with a **chair in the path** half way | Explore warns before contact |
| On the table: a **microwave** (or a printed panel with START and STOP at least 3 cm tall), a **food carton with a barcode**, a **knife** flat on a plate | Find, product lookup, hazard fence |
| A printed **sign** ("EXIT" or "KITCHEN") on the wall at eye level | Explore reads signs on its own |
| Phone: Wi-Fi or hotspot on, voice server awake (`npx -y freestyle@latest vm get echoguide-voice`), app in **Explore** | Kokoro voice, no cold start |
| Rehearse the walk twice with the blindfold on. Note where the app speaks. | Timing |

## Script

| Time | Tester does | App says / room sees | Narrator says |
|---|---|---|---|
| 0:00 | Stands at the start mark, blindfolded | Screen: live camera, boxes appear on the room | "2.2 billion people have a vision impairment. Every AI app for them has the same shape: point, ask, answer. Watch what happens when the AI acts on its own." |
| 0:10 | Starts walking toward the table | "A chair, ahead." then as they close: "Careful. Chair is close." plus a buzz. Overlay: orange border | "No prompt. It names what matters, once, nearest first, and warns before contact. All on the phone." |
| 0:25 | Reaches the table, turns toward the sign | "Sign: EXIT." "A microwave, ahead." | "It reads signs on its own. Now the hard part. Knowing there is a microwave does not help you find Start on a flat panel." |
| 0:35 | Presses the mic, says "find the start button" | "Heard: start button." "Looking for start button." Screen switches to Find, camera stays up | "Find mode. Say what you want." |
| 0:42 | Raises index finger toward the panel | "Start. Move right." Pulses speed up as the finger closes in. Overlay: dashed line from fingertip to the green box | "Pulse rate is distance. Sharpness is up or down. Left and right come through the audio." |
| 0:52 | Finger lands on START and holds still | Double tap. "Hold still." Dwell ring fills in 0.8 s. "Done. Start." Screen flashes green | "Holding still is the confirmation. Hooked to Home Assistant, that press starts the real microwave. Nothing physical fires without that hold." |
| 1:02 | Picks up the carton, turns it toward the camera | "Oat milk. Contains oats." | "Barcode, product lookup, read-only, so it fires on sight. No finger needed." |
| 1:10 | Reaches toward the knife | "Careful. Knife is close." Red border. Then "Stop. Knife." as the hand enters | "Hazard fence. Hazards preempt everything, and they cancel any press in progress." |
| 1:20 | Narrator toggles Airplane Mode on the phone, tester says "find the stop button" | Still guides, on-device voice takes over | "Airplane Mode. Same product. The cloud is a bonus, never a dependency." |
| 1:28 | Done | | "On-device YOLO and hand tracking, under 15 ms frame to cue. Open-weight Kokoro voice on a Freestyle VM, snapshotted so it boots warm. MCP for actions. EchoGuide." |

## If something goes wrong

- **Nothing spoken on the walk**: the room is too still. The tester should sweep the phone slowly; motion wakes the pipeline.
- **Find does not settle**: text too small or glare. Move 30 cm closer, hold 1 s.
- **Voice sounds robotic**: the Freestyle VM is asleep or Wi-Fi dropped; the on-device voice has taken over. Nothing else changes.
- **Knife not detected**: use the hob rule instead (anything labelled "oven" is a hazard zone) or skip the beat. The fence story is told by the "Careful" chair moment already.

## What judges are scoring, and where it is in the demo

| They ask | The beat that answers |
|---|---|
| Is it a real problem? | 0:00 and 0:25: point-ask-answer leaves the last 10 cm unsolved |
| Does it work live? | Every beat is live; nothing is recorded |
| What is technically hard? | 0:42 to 0:52: closed-loop haptic guidance with dwell-to-act, local, under 15 ms |
| Is it novel? | Acting unprompted (0:10) and leading a hand onto a flat control (0:52). Describing scenes is common; this is not |
| Did you use the sponsor stack? | 1:28: Kokoro on Freestyle, snapshot-warm |
| Could this ship? | Offline at 1:20, MCP plugins per home, benchmark protocol in `benchmarks/` |
