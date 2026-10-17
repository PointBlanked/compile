# Head-to-head benchmark protocol

Owner: Maxwell. Purpose: measure EchoGuide against the apps blind and low-vision people already use, on the same tasks, with numbers anyone can check. No claim about being better goes in a pitch unless it comes from this sheet.

## Products

| Product | Notes |
|---|---|
| EchoGuide | This app. Trials are timed automatically (Settings → Run a benchmark task). |
| Google Gemini Live, Guided Vision | Android. Launched October 1, 2026. |
| Apple Live Recognition / Point and Speak | iPhone Magnifier. Point and Speak needs LiDAR. |
| Be My Eyes (Be My AI) | AI image description. Use the AI mode, not volunteers, so the comparison is fair. |
| Microsoft Seeing AI | Short Text, Document, Product, Scene channels. |

## Tasks (run all eight, in order, on every product)

| # | Task | EchoGuide mode | What success means |
|---|---|---|---|
| 1 | Find and press the Start button on a microwave or labelled panel | Find | Finger is on Start and it is pressed |
| 2 | Find a specific product on a table of five, by its label | Find | Hand is on the right item |
| 3 | Read the first line of a printed letter | Read | First line read correctly |
| 4 | Identify a packaged food by its barcode | Find | Product named correctly |
| 5 | Walk 5 m down a corridor and get warned before a chair in the path | Explore | Warning comes before contact |
| 6 | Say what is on the table without being asked | Explore | Things named with no prompt |
| 7 | Describe the room in one request | Describe | Main objects and their positions correct |
| 8 | Task 1 again in Airplane Mode | Find | Same as task 1 |

## Setup

- The same room, lighting, objects and tester for every product. Randomise product order per tester, so learning does not favour whichever goes last.
- The tester is blindfolded (or is a blind or low-vision participant, with consent). A second person keeps time and does not help.
- Start the clock when the tester says "go"; stop at success, or at 120 s (counts as failed).

## What to record (CSV columns)

| Column | Meaning |
|---|---|
| `duration_s` | Go to success, or 120 for a fail |
| `success` | 1 or 0 |
| `first_cue_ms` | Go to the first useful thing heard or felt |
| `user_prompts` | Times the tester had to tap, speak, or ask again |
| `spoken_lines` | Sentences the product spoke (noise if high and unhelpful) |
| `cloud_calls` | Network requests (EchoGuide counts them; others: 0 if unknown) |
| `offline` | 1 if the trial ran without a connection |

EchoGuide fills every column itself. For other apps, use **Settings → Add a result from another app**, so all results land in one CSV (**Export CSV**). `scoresheet.csv` is a blank copy for paper.

## How to report

Per task and product, report the success rate, the median time, and the median prompts, with n (number of trials). With fewer than 5 trials per cell, call the result "early" and do not claim significance.

The comparisons this battery is designed to show, if they hold up:

- **Tasks 1, 2 and 4:** guidance onto a control. Others describe or read; they do not lead the finger to a target. Expect EchoGuide to win on success and time.
- **Tasks 5 and 6:** proactive, with no prompts. Others answer when asked; `user_prompts` shows the difference.
- **Task 8:** offline. Cloud-first products are expected to fail.
- **Tasks 3 and 7:** reading and description, where the incumbents are strong. Report these honestly even if EchoGuide loses; that is where the cloud model and photo consent matter.

Also run the on-device speed test (Settings → Measure on-device speed) on the phone used, and report its p50 and p95 next to the task results.
