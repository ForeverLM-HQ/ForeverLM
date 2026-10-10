# Welcome clips

Screen recordings that loop under setup's subscription question, in its
connector plan, and under the AI step's two OpenRouter links
(`App/GettingStartedGuide.swift`). A step plays the clip named
below if it is in this folder and shows its words alone if not, so a clip can
be added, replaced or removed without touching code. The welcome itself plays
no clips since 2026-09-24: its three pages became one page of three rows.

## Every clip

- Record the Dev build with a **demo library**, never a real one: no real
  names, emails, chats, API keys or account details on screen.
- Recordly, one window, 16:10 (the frame is 384 × 240 pt). Export H.264 `.mp4`
  at 1152 × 720 or larger, no audio, under 4 MB.
- 6–10 seconds that loop cleanly: end on the frame you started on.
- Slow cursor moves, auto-zoom on the click that matters. No captions: the
  page beside it already says what it means.

## The clips

| File | Page | Show |
|---|---|---|
| `setup-codex-library.mp4` | Setup: Do you already pay for an AI subscription? (until an app is ticked) | Codex (in the ChatGPT app), in an empty project: `@ForeverLM what papers and podcasts do I have on bioelectricity?` is typed and sent, the connector's calls run (sped up), and the answer lists the library's papers and podcast episodes, then fades back to the empty composer. Codex sidebar hidden, so no other chats show; filmed on the curated Bioelectricity library in Screen record mode. |
| `setup-openrouter-credits.mp4` | Setup: AI step, "Your OpenRouter key", under "Add credits at OpenRouter" | Safari on openrouter.ai/settings/credits, signed in: Add Credits, $10 typed in, and the pointer comes to rest on the pay button without pressing it. |
| `setup-openrouter-privacy.mp4` | Setup: AI step, "Your data", under "Open OpenRouter privacy settings" | Safari on openrouter.ai/settings/privacy: the paid and free "endpoints that may train on inputs" switches are turned off, which is what the row asks for. |

## OpenRouter clips

The two OpenRouter clips are real third-party pages, filmed in Safari (product owner,
2026-09-27) because that is the browser every Mac learner has. The same rules
as the connector walkthroughs apply: blur the account name, email, avatar,
balance, card and anything else of the account's. Nothing is ever paid: the
credits take ends before the pay button. The privacy take changes a real
account's switches, so every switch goes back to what it was straight after
the take. These clips follow the page, not ForeverLM: re-record one when
OpenRouter redesigns its page, or when the row's text asks for something else.

## Connector walkthroughs

Setup's "Connect ForeverLM" plan plays `connector-<app>.mp4` in an app's open
row: `connector-claude`, `connector-chatgpt`, `connector-grok`,
`connector-gemini`, `connector-other`. Each one films that app's
`AISubscription.connectorSteps`, in order, ending on the app showing ForeverLM
connected. Unlike the welcome clips these are real third-party pages, so blur
or crop the account name and avatar, and remove the test connector afterwards.

Every connector clip needs an entry in `connector-clips.json` naming the steps
it shows, word for word, and the day it was recorded:

```json
{ "clips": { "connector-claude": { "recorded": "2026-09-24", "steps": ["In Claude, open Customize › Connectors", "…"] } } }
```

`GettingStartedTests` fails when a clip has no entry or its steps no longer
match `connectorSteps`: change the steps and the clip has to be re-recorded
(or removed) in the same change. The steps can also go stale because the app
itself changed its menus; that check needs a signed-in browser and runs
outside the unit tests.
