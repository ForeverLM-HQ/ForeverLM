# ForeverLM launch video — Recordly production plan v2

## The decision

The website hero is not a tour. It is one proof:

> Save something worth understanding. Ask across everything. Open the evidence. Make it stick.

The hero must make that loop legible without sound in under 18 seconds. A separate 42-second launch film explains breadth. Individual feature clips document the rest of the product.

## Why the current live loop fails

- The opening image is a large butterfly page beside an empty browser Reading List. It does not read as ForeverLM or as a useful outcome.
- The video changes jobs before the viewer can understand any one of them.
- Much of the product UI is too small at the size used on the homepage.
- The ChatGPT scene gives a third-party product the most visually prominent moment.
- The captions name features, but the footage does not form a cause-and-effect story.
- The footage mixes unrelated subjects. It does not feel like one real person's coherent library.
- There is no clear before and after, and no final frame that answers “why would I want this?”

The current asset should be replaced, not refined.

## One coherent demo world

Every shot uses the **Bioelectricity** notebook and the same visible vocabulary:

- Michael Levin and bioelectricity
- *We Are Electric*
- *How Life Works*
- related public papers and articles
- a small number of relevant podcasts and YouTube videos
- public Michael Levin X posts
- only the permitted Stanford AI + Biomedicine seminar folder under Meetings

Screen-record mode stays on for the entire session. “Also show the library's public sources” stays off; every source intended for the video belongs in the Bioelectricity notebook. Only the seminar folder is allow-listed. The privacy settings themselves never appear in footage.

## Deliverables

1. **17-second silent hero loop** — website autoplay; one story, large UI, no narration.
2. **42-second launch film** — Product Hunt, Reddit, X, and the website's optional “Watch the tour”. Narrated and captioned.
3. **Nine atomic clips** — 6–12 seconds each, saved as editable `.recordly` projects. These feed feature sections and can be recut later.
4. **24-second social cut** — 16:9 and 9:16 variants, built from the same masters.
5. **Poster image** — the cited answer beside its source, not an empty browser state.

## The 17-second website hero

### Exact Recordly camera map

Coordinates below are percentages of the captured app window, measured from its top-left. `1.00×` means the full window. Recordly's zoom transitions use smooth ease-in-out without overshoot. Cursor movement finishes before the camera moves; the camera never chases a moving cursor.

| Time | Scale and focus | Recordly motion | Reason |
|---|---|---|---|
| 0.00–0.55 | `1.08×`, notebook title `(37%, 30%)` | Completely still | Let the viewer identify ForeverLM and the notebook before directing attention. This exactly matches the loop's final framing. |
| 0.55–0.95 | `1.08× → 1.18×`, source list `(27%, 42%)` | 400 ms ease-in-out | Bring the books, papers, podcast, video and X row to readable size. |
| 0.95–2.15 | `1.18×`, source list | Hold | The source variety is the point; no pan and no cursor movement. |
| 2.15–2.40 | `1.18× → 1.06×`, center `(50%, 50%)` | 250 ms ease-out | Open the composition before the browser cut. Do not zoom fully out. |
| 2.40 | Browser at `1.06×`, post center `(50%, 48%)` | Hard cut on matching window scale | The subject changes, so a cut is clearer than a pan. |
| 2.55–2.90 | `1.06× → 1.32×`, bookmark control `(68%, 68%)` | 350 ms ease-in-out | Make the single browser action unmistakable. |
| 2.90–3.55 | `1.32×`, bookmark control | Hold; click at 3.18s | The camera is already settled before the click. Keep 370 ms after the state changes. |
| 3.55 | ForeverLM at `1.06×`, top of source list `(28%, 27%)` | Hard cut immediately after bookmark state changes | Cut on the completed action, not while the cursor is moving. |
| 3.65–4.05 | `1.06× → 1.28×`, newly arrived row `(27%, 23%)` | 400 ms ease-in-out | Connect the browser action to the new ForeverLM row. |
| 4.05–5.00 | `1.28×`, new row | Hold | Give the title enough time to be read. Cursor remains away from it. |
| 5.00 | Chat at `1.00×`, centered | Hard cut | Reset spatially before starting the question. |
| 5.15–5.50 | `1.00× → 1.22×`, composer `(56%, 84%)` | 350 ms ease-in-out | The full pre-typed question becomes legible. |
| 5.50–5.78 | `1.22×`, composer | Hold; click Send at 5.58s | No wait or spinner follows. |
| 5.78 | Finished answer at `1.08×`, answer body `(56%, 44%)` | Hard cut on click | The cut compresses model latency honestly without showing fake speed. |
| 5.78–6.20 | `1.08× → 1.18×`, first answer paragraph `(55%, 38%)` | 420 ms ease-in-out | Direct attention to the answer, not the surrounding app chrome. |
| 6.20–8.45 | `1.18×`, answer body | Hold | This is the longest still shot after the evidence shot. Let the viewer read. |
| 8.45–9.20 | `1.18× → 1.30×`, first book citation `(62%, 67%)` | 450 ms ease-in-out, then 300 ms hold | Visually announce that the citation is actionable before the cursor clicks it. |
| 9.20 | Citation at `1.30×` | Click, then hold 180 ms | The click finishes at the same scale; do not begin panning during it. |
| 9.38 | Split answer/Reader at `1.00×`, center `(50%, 50%)` | Hard cut after the Reader has opened | A full split view establishes the relationship between answer and source. |
| 9.38–9.90 | `1.00×`, split view | Hold | This half-second orientation shot prevents the next close-up from feeling dislocated. |
| 9.90–10.35 | `1.00× → 1.24×`, highlighted passage `(74%, 51%)` | 450 ms ease-in-out | Focus the exact evidence while retaining enough of the answer to the left. |
| 10.35–12.40 | `1.24×`, highlighted passage | Hold | This is the hero's proof moment. No cursor movement. |
| 12.40 | Interactive explanation at `1.00×`, center | Hard cut | Reset before the final payoff. |
| 12.55–12.90 | `1.00× → 1.16×`, interaction control `(34%, 68%)` | 350 ms ease-in-out | Show what is about to be changed. |
| 12.90–13.35 | `1.16×`, interaction control | Hold; click at 13.05s | Let the input state visibly change. |
| 13.35–13.80 | `1.16×`, pan only to result `(64%, 48%)` | 450 ms smooth pan, no scale change | The effect is elsewhere on the same canvas; a pan expresses cause and effect. |
| 13.80–14.90 | `1.16×`, changed result | Hold | Let the visual consequence land. |
| 14.90–15.35 | `1.16× → 1.00×`, center | 450 ms ease-out | Close the interaction and prepare the end frame. |
| 15.35 | Bioelectricity notebook at `1.00×`, center | Hard cut | Return to the opening visual world. |
| 15.35–15.85 | `1.00× → 1.08×`, notebook title and new row `(37%, 30%)` | 500 ms very gentle push | The end is a confident hold, not another feature reveal. |
| 15.85–17.00 | `1.08×`, notebook title and new row | Hold | “ForeverLM for Mac” appears. The cursor is hidden or parked outside the product window. |

The first and final frames use the same `1.08×` scale and `(37%, 30%)` anchor, so the loop has no camera reset. The visible source state should also match: record the opening after the X post has already arrived, and use a different duplicate take for the middle “arrival” beat.

### Zoom principles for the longer cut

The 42-second film reuses these same atomic camera moves. It does not invent a second set of zooms. The only additional rule is that every new source format begins with a 350–500 ms full-window orientation shot before the camera moves closer. Never pan between unrelated panels, never auto-zoom on every click, and never exceed `1.35×`.

### 0.0–2.4 — A real library, immediately

Open on ForeverLM, not the browser. The Bioelectricity notebook is selected. Books, papers, a podcast, a video and a saved post are visible at a readable scale.

Overlay: **Everything you learn, connected.**

Camera: static for 0.6 seconds, then one gentle 1.15× push toward the source list.

### 2.4–5.0 — Save from the browser

Hard cut to one clean Michael Levin X post. Click Bookmark. Hard cut back to ForeverLM as that exact post appears at the top of the notebook.

Overlay: **Save it once.**

Do not show an empty Reading List, browser chrome clutter, other tabs, profiles or notifications.

### 5.0–9.2 — Ask across the whole subject

The prompt is already typed: **“How do bioelectric networks store and pursue anatomical goals?”** Click Send. Cut directly to the finished answer with two visibly numbered citations from different source types.

Overlay: **Ask across every source.**

The answer should have two short paragraphs, not a wall of text.

### 9.2–12.4 — Verify the claim

Click the citation to *We Are Electric*. The Reader opens beside the answer on the exact highlighted passage.

Overlay: **Open the exact evidence.**

This is the main differentiator and receives the longest uninterrupted hold.

### 12.4–15.4 — Turn understanding into learning

Match cut to the interactive planarian explanation or a guided walkthrough using the same notebook. Show one unmistakable interaction, not a gallery of output buttons.

Overlay: **Make it stick.**

### 15.4–17.0 — End and loop

Return to the Bioelectricity notebook with the newly saved X post visible. Small end lockup: **ForeverLM for Mac**. The final composition should be close enough to the opening frame for a clean loop.

No ChatGPT, settings, model picker, pricing, meetings or full output inventory in the hero.

## The 42-second launch film

### Edit

| Time | Visual | Spoken idea |
|---|---|---|
| 0–4s | Rapid but readable cuts: book, paper, podcast, video, saved post inside one notebook | Research does not arrive in one format. |
| 4–9s | X bookmark and browser Reading List save; both appear in ForeverLM | Save what matters from the places you already use. |
| 9–17s | Ask the bioelectricity question; source-backed answer appears | Ask across the whole subject, not one uploaded file. |
| 17–24s | Open a citation into the exact book passage, then a paper figure | Every claim remains attached to evidence. |
| 24–34s | Guided walkthrough, memory card with source, interactive planarian explanation | Turn the same knowledge into ways to understand and remember it. |
| 34–38s | Brief notebook overview showing the range of source types | The breadth is visible without another feature list. |
| 38–42s | ForeverLM window, iCloud and “Choose your model” marks, CTA | Private library, learner-controlled model, Mac CTA. |

### Voiceover — 76 words

> Research doesn't arrive in one format. It lives in papers, books, podcasts, videos, meetings, and the posts you save. ForeverLM brings them into one private library. Ask a question across all of it, and follow every claim back to the exact source. Then turn the same material into a walkthrough, memory cards, or an interactive explanation. Your library stays in iCloud, and you choose the AI model. This is ForeverLM for Mac.

The voice is calm and matter-of-fact. It should sound like a researcher showing a useful workflow, not an advertisement read.

## Atomic capture list

Record each item as its own project. Capture three takes: deliberate, natural, and fast. Every take starts and ends with a one-second hold.

| ID | Length | Action | What must be readable |
|---|---:|---|---|
| A | 6s | Open Bioelectricity notebook and select across source types | The two books plus paper, podcast, YouTube and X rows |
| B | 9s | Bookmark one public Michael Levin X status, return to ForeverLM | The same post appearing at the top of the notebook |
| C | 9s | Add a public bioelectricity article to the browser Reading List, return | The article appearing without a manual import step |
| D | 12s | Send the anatomical-goals question and reveal the completed answer | Two concise paragraphs and citations from different formats |
| E | 9s | Open the book citation beside the answer | Exact highlighted passage and book title |
| F | 8s | Start or advance a guided walkthrough | One source figure and one clear tutor step |
| G | 8s | Reveal a memory card, answer it, then open its evidence | Prompt, answer and source link |
| H | 8s | Interact once with the planarian explanation | Cause-and-effect change on screen |
| I | 10s | Generate/open the polished bioelectricity Page or Site | Clear transformation from notebook to finished output |

Meetings, MCP in ChatGPT/Claude, model selection, audio generation and video generation get secondary clips only after the core nine are excellent. They do not enter the launch cut merely to prove completeness.

## Recordly preset

- Capture one app window at a time, never the whole desktop.
- Source capture: Retina, 2456×1380 or higher, 60 fps.
- Composition: 16:9, exported master at 1920×1080; website derivative at 1280×720, 30 fps, H.264 fast-start.
- Window scale: roughly 88–92%, with 56–64 px of breathing room.
- Background: quiet mint/lilac/coral gradient matching the homepage; no photographic wallpaper.
- Corner radius: 18–22 px. Shadow: soft and restrained.
- Cursor: 1.25–1.35×, medium smoothing, subtle click bounce, low motion blur.
- Zooms: manual after capture. Use 1.18–1.35×, 350–500 ms easing, no more than two in an atomic clip.
- No webcam. No microphone for atomic masters. Record the launch narration separately.
- Remove waits. Cut to finished AI output instead of accelerating a spinner.
- Do not use crossfades between app actions. Use clean hard cuts or matched compositions.

Recordly supports manual and suggested zoom regions, smooth pan transitions, cursor smoothing, click effects, backgrounds and editable project files; use those tools to direct attention, not to make the frame constantly move.

## Capture staging

1. Build and run ForeverLM Dev from the approved branch. Do not replace or film the production app while the feature is unreleased.
2. Turn on screen-record mode and select Bioelectricity plus the single public seminar folder.
3. Verify every app surface—source lists, search, chat pickers, Pages, Meetings and MCP—shows only allowed material.
4. Use a fresh browser profile with no personal tabs, bookmarks bar, extensions, avatars or notifications.
5. Choose an X status and article that are not already in the Dev library, or the “appears instantly” take will be dishonest.
6. Pre-generate the cited answer, walkthrough, card and interactive explanation once so the final take never shows unpredictable model latency.
7. Set the ForeverLM window to a fixed 16:9 size. Increase interface/text scale until titles remain readable in a 1280 px export.
8. Disable notifications, menu-bar distractions and dock appearance. Use Do Not Disturb.
9. Capture each atomic take separately and save the `.recordly` project immediately.
10. Review every raw take frame by frame for private names, other notebook titles, account avatars, URLs and notification remnants before editing.

## Overlay system

Use only these four story lines in the hero:

- **Everything you learn, connected.**
- **Save it once.**
- **Open the exact evidence.**
- **Make it stick.**

Maximum six words per overlay. One weight, sentence case, bottom-left placement, 5% safe margin. Hold at least 1.4 seconds. The overlay must never cover the action.

The longer film may also use **Ask across every source** and **Private in your iCloud**.

## Acceptance gate

The new hero does not ship until all are true:

- A muted first-time viewer can say “it connects my sources, answers with evidence, and helps me learn” after one loop.
- ForeverLM itself is visible in the first frame and for at least 80% of the runtime.
- The saved browser item is visibly the same item that appears in ForeverLM.
- At least two source types support the answer on screen.
- One citation opens to an exact readable passage.
- No text essential to the story is smaller than approximately 16 px in the 1280×720 derivative.
- No loading spinner, empty state, accidental scroll, cursor hunt or dead air survives the edit.
- No unrelated company, meeting, account, notebook or private material is visible.
- The poster frame is meaningful on its own.
- The final frame loops cleanly to the opening frame.
- The file is under roughly 5 MB where visual quality permits, respects reduced-motion, and has a static poster fallback.

## Production order

1. Capture A–E first. Assemble a rough hero with no styling.
2. Watch it at the actual homepage width, muted, once. If the save → answer → evidence chain is not obvious, reshoot before adding polish.
3. Capture F–I and choose only one learning payoff for the hero.
4. Apply the Recordly preset and overlays.
5. Export the 17-second hero and poster; test desktop and mobile crops.
6. Build the 42-second narrated film from the approved masters.
7. Derive the social cut last. Do not let social pacing compromise the website version.

