# ForeverLM launch video — Recordly production plan v2 (the learner's journey)

## The decision

The launch story is a person learning something, from nothing, in ForeverLM. It is not a tour of a finished library.

> (product owner, 2026-10-11: "it would be cleaner to go through the workflow from scratch; show how we would learn about bioelectricity; and show how it would pull together sources from podcasts, youtube etc; and we can watch them etc")
>
> (product owner, 2026-10-11: "you have to make that a more natural story; where the user is on a journey i want to learn about bioelectricity")
>
> (product owner, 2026-10-11: "that should ultimately inform the script and the recordly. and it should also inform how we want to have the screen recording mode and what sources and chats etc should be visible in there")

So the journey is the spine. The script, the Recordly camera maps, the capture list, the staging and Screen record mode's rules all follow from the seven beats below. The populated showcase notebook is no longer the hero: filmed in recording mode it read as someone else's finished, abandoned workspace (all rows ticked, truncated titles, near-blank paper previews that look like failed loads, every row "3 weeks ago", a floating pill over the last row, a heavy composer with the model chip, nine pastel tiles beside a long list, an empty top bar with a lone ×). A from-scratch take cannot have those faults: everything on screen was made a minute ago, for the story.

## The learner

Someone who watched a clip of a two-headed flatworm and wants to know how a cell "decides" what body to build. Not a biologist. Calm, curious, a little unsure. Never says "AI", never says "workflow".

## The seven beats

| # | Beat | The learner's question | What happens on screen | Overlay (≤ 6 words) | Atomic clip |
|---|---|---|---|---|---|
| 1 | Curiosity | "Where do I even begin?" | A notebook called Bioelectricity, empty on purpose. The goal is typed in plain words: "I keep hearing that voltage tells cells what to build. I want to actually understand it." | I want to understand this. | J1 |
| 2 | Where do I start? | "What should I read first?" | Web Discover returns candidates, each with its kind and one line on why it fits: a talk, a podcast episode, an article, a book from the learner's own library, one paper. The friendly ones are ticked, the hard paper is left for later. They land with their covers and transcripts filling in. | It finds where to begin. | J2 |
| 3 | Watch the easy one first | "What does that sentence mean?" | The talk plays with its transcript beside it. Pause on the worm, select a sentence, ask what it means. The answer uses that passage and a second source. | Ask while you watch. | J3 |
| 4 | Take it with you | "Does this connect?" | The podcast episode opens with its transcript. One line catches the learner; asked about, the notebook answers from the episode and the talk. | Listen anywhere. It all connects. | J4 |
| 5 | Now the real question | "How do bioelectric networks store and pursue anatomical goals?" | The hard paper is added now. The answer cites the book, the talk and the paper; a click on the book citation opens the Reader at the exact passage. | Every claim opens its source. | J5 |
| 6 | Do I really get it? | "Can I explain it back?" | The product's core idea. A review: explain the two-headed worm in their own words. The first try is shaky, the tutor says what is missing, the second lands. | Say it yourself. Find the gaps. | J6 |
| 7 | Make it stick, then step back | "What do I have now?" | A few memory cards. Then the notebook seen whole: sources the learner now understands, the cards to check. | From curious to knowing. | J7 |

The loop of the website hero is these beats compressed (below). The film tells all seven. Each beat is also an atomic clip sharing its master with both.

## Can it be filmed today? (checked against the code, 2026-10-11)

Nothing here is invented. "Works" means the wiring exists and was read, not that a take was made; every row needs a rehearsal take before the shoot.

| Beat | Verdict | What the code does today | Risk and what would have to change |
|---|---|---|---|
| 1 | Works with a caveat | New ▸ Notebook makes "New notebook" at once with no form (`StudioViewModel+NotebookNaming.swift`). ForeverLM names it after the first source or exchange, but never renames a notebook whose title the learner typed (`NotebookNaming.swift`), so rename it Bioelectricity first. The empty notebook shows "No sources yet", the Sources search field and the chat guide (`NotebookContextPanel.swift`, `NotebookChatGuide.swift`). | **There is no field for a goal when a notebook is made**; the notebook's Instructions and research questions have no Mac UI (their setters have no UI callers). The goal sentence is typed into the Sources search field with the Web chip: that is Discover's real input (`NotebookSourcesSearch.swift`). The field is one line in a narrow column, so a long sentence scrolls: burn the sentence in as a caption, or widen the Sources column for this beat. |
| 2 | Works with caveats | The Sources search field with the Web chip and Return runs Discover (`StudioViewModel+NotebookDiscover.swift`, `WebSourceDiscovery.swift`): one paid search, rows with kind, site, year and a "why" line, web rows start ticked, import one at a time, then one toast. A YouTube import fetches its thumbnail and transcript at once (`StudioViewModel+Queue.swift`). A row the library holds is filed, not imported. | (a) **There is no "Discover" button under Add sources** (that sheet is library-only, `NotebookAddSourcesSheet.swift`). (b) **The list is flat, not grouped by kind, and rows carry a 16 pt favicon, not a cover** (`NotebookDiscoverView.swift`): the kind reads as a text line. (c) **Discover never lists a book** (`Prompts.swift`: it bans shop and publisher book pages): the book comes from the learner's own library (below). (d) A podcast imports cleanly only from an Apple Podcasts episode link (`StudioViewModel+Queue.swift`); other hosts stage an "Is this the right podcast?" card or end in an error. (e) Article covers may stay a blue document icon with the domain as the title in the notebook column: nothing fetches content or artwork right after a plain article lands (`NotebookContextPanel.swift` row). (f) The search wait is a bare spinner and unbounded. (g) Which candidates come back is the model's; re-take until the five kinds are there. Changes if wanted: kind sections and covers in `NotebookDiscoverView.swift`; a post-insert artwork and content fetch for articles; a `book` kind in `WebSourceDiscovery`. |
| 3 | Works with caveats | A YouTube source opens `YouTubeVideoReaderView` (`YouTubeReaderViews.swift`): the watch page with the transcript beside it, the current line highlighted, a click on a line seeks and plays. Selecting transcript text raises the selection bar (`ReaderSelectionCallout.swift`); its Chat button stages the passage as a quote chip in a new chat (`StudioAssistantBar.swift`). Typing a question pauses the player (`ReviewSessionManager.swift`, `readerVideoPauseRequest`). Citations show moment chips that seek the video. | (a) The bar says "Chat", not "Ask about this", and Chat does **not** send: the learner types the question. (b) Whether the answer also draws on the notebook's other sources depends on the model reaching for them (the handoff stages only the video); word the question so it does ("What does that mean? Does the article say the same?") and confirm on rehearsal that two sources are cited. (c) A new video shows "Fetching transcript…" and swaps raw captions for formatted text in place: a selection can be lost, so film after the transcript has settled. (d) The Reader stacks video over transcript below about 708 pt of width: use a wide window. (e) The watch page is a live web view: ads or a consent screen can appear. |
| 4 | **Partly absent** | A podcast episode opens a **static transcript** (`TranscriptReaderView`, `playhead: nil` in `TranscriptReaderViews.swift`): no audio, no line following playback. "Open Podcast" hands off to Apple Podcasts. Only a podcast filed under a YouTube address opens the video Reader, which does follow along. The transcript comes from Apple's transcript API and is held back until the paid formatting model finishes ("minutes" for a long episode, `StudioViewModel+PodcastTranscripts.swift`). | **"Plays with the transcript following" cannot be filmed as written.** Two honest cuts: (P1) film an episode that also has a YouTube version, filed as that video, so the Reader plays it and follows the transcript (the learner sees a conversation, not a video of slides); (P2) film the transcript read-along with no playback and say "with its transcript", never "plays". What would have to change for a true podcast player: `TranscriptReaderViews.swift` (an audio source and a playhead) and `SourceReaderPanel.swift`. Decision for the product owner. |
| 5 | Works with caveats | A citation opens the Reader beside the chat on the passage (`StudioViewModel+Navigation.swift`, `readerPassageTarget`): an EPUB chapter, stored chapter text, or a PDF; a talk citation seeks and plays. Markers are numbered only when more than one source is cited; a "Sources" footer lists them (`chat-dom.js`). | (a) **The passage highlight is a flash of about 3.2 s that fades out by about 3.6 s** (`ReaderPassageFlashSupport.swift`): the proof hold must start at the cut and end inside it. (b) The exact passage depends on the model copying a 6–20 word excerpt exactly (`ReviewSessionManager.swift`); a garbled excerpt opens the chapter top with no mark: plan retakes. (c) If the book's EPUB file is not on the Mac the stored chapter text opens (still flashes). (d) A talk citation starts playback. (e) The paper must be open access so its PDF lands without a "PDF needed" badge. |
| 6 | Works with a large caveat | The learner's route is the empty chat's "Quiz me on it" chip (`NotebookChatGuide.swift`, `startNotebookReviewFromIdle` in `InternalReviewPanel.swift`): the tutor writes a "Review plan" checklist and a first question, evaluates in prose and keeps asking about the same concept until it lands. Typed or dictated. | (a) **There is no gap list or "what is missing" widget**: the gaps are the tutor's prose (`Prompts.reviewTutor`, `ReviewChatComponents.swift`); the in-app review writes no gaps or understanding (`record_understanding` is MCP-only). The film shows the prose, large. (b) **The learner cannot name the topic**: it is the notebook title with every ticked source as material; untick everything except the worm sources before opening a New chat. (c) The chip shows only in an empty chat. (d) Every turn is a paid model call with dead air: cut it. (e) It ends on `/end`; the summary is a small grey caption. To make the gap list a real surface: `Prompts.reviewTutor` plus a card in `ReviewChatComponents.swift`. Decision for the product owner. |
| 7 | Works, with one absence | Cards: the Studio Cards tile ▸ Make Cards… (Auto, 10, 20 or 40, a focus, **a price line**) runs as a pending output, then To Check, then Keep N Cards (`MakeCardsSheet.swift`); or type "make three cards from this" in the chat and a deck draws with Check Cards and Keep All (`ReviewChatSavedCardsView`). A Cards row reads "N kept · M due · K to check" once cards exist (`NotebookStudioViews.swift`). The notebook opens as Sources, chat and Studio. | (a) **A goal has no tick inside a notebook**: Goals only show "Done" in the Goals tab after a manual Mark done (`GoalsViews.swift`). Until the product gives a notebook a goal state, the overview ends on sources and cards, not a tick (decision for the product owner). (b) The Make Cards sheet shows a price: use the chat route, or crop. (c) The chat route needs the model to call `save_card_drafts`. |

Cross-cutting: every model turn (Discover, answers, review, cards) is a paid call and slow, so every take costs real money and needs cut waits; measure one rehearsal's cost in the app's own cost line and write it here before the shoot.

## Deliverables

1. **17-second silent hero loop**: website autoplay; beats 2, 3 and 5 compressed, framed by beat 1's typed goal and beat 7's notebook (beat 4's podcast is a row among the sources, so the hero does not depend on its risk). First and last frame match.
2. **58-second launch film** (the 42–60 s film): all seven beats, narrated and captioned, for Product Hunt, Reddit, X and the website's "Watch the tour". A **42-second cut** drops beat 4 and trims the rest.
3. **Seven atomic clips** (J1–J7) and the short J2b insert, 5–12 seconds each, saved as editable `.recordly` projects. They share masters with the film and the hero.
4. **24-second social cut**, 16:9 and 9:16, from the same masters.
5. **Poster image**: the cited answer beside its highlighted passage (J5's split view).
6. **Secondary clips**, only after the seven are excellent: the browser arrival of an X bookmark and of a Reading List page, a guided walkthrough, the planarian interactive explanation, the finished Page, Meetings, MCP in another assistant, model choice. None enters the launch cut to prove completeness. The browser arrival no longer serves a beat (the learner's sources come from Discover), so it moved here; Screen record mode still supports it (a Reading List or X origin earns a pass, and returning from the browser checks at once).

## The film's script

A learner, first person, calm. No ad voice: the pace of someone thinking aloud, about 2.4 words a second. Overlay = the beat's story line (≤ 6 words, bottom-left). Caption = a second line, ≤ 8 words, bottom-left under it, there so the film reads with no sound on X. At most two text lines on screen, never over the action, each held at least 1.4 s. A bracketed caption is dropped in the 42-second cut.

| Time | Beat | Picture | Voice-over | Overlay | Caption |
|---|---|---|---|---|---|
| 0.0–6.0 | 1 | Empty notebook "Bioelectricity"; the goal typed; Web chosen | "I watched a flatworm grow two heads. I wanted to know how." | I want to understand this. | Voltage tells cells what to build. |
| 6.0–17.5 | 2 | Discover rows with their whys; the paper unticked; the sources land; my book added from the library | "I didn't know where to start, so I asked. It found a talk, a podcast and an article, and said why. I added my book." | It finds where to begin. | [A talk, a podcast, an article, my book.] / Hard paper? Later. |
| 17.5–26.0 | 3 | The talk and transcript; pause on the worm; a sentence selected; the question; the answer | "I started with the talk, and paused on the worm. I didn't follow one sentence, so I asked what it meant." | Ask while you watch. | What does that mean? |
| 26.0–32.0 | 4 | The episode's transcript; a line caught; asked about | "Then a podcast. One line caught me, and the notebook picked it up." | Listen anywhere. It all connects. | One line, from a different source. |
| 32.0–41.0 | 5 | The paper lands; the question; the cited answer; the book citation opens its passage | "Now the real question. The answer cites the book, the talk and the paper, and one click opens the exact passage." | Every claim opens its source. | The book, the talk, the paper. |
| 41.0–50.0 | 6 | Quiz me on it; the first try; what is missing; the second | "Do I really get it? I explained the worm myself. The first try had gaps; it showed me where. The second landed." | Say it yourself. Find the gaps. | Explain it back. |
| 50.0–55.5 | 7 | Three cards kept; the notebook whole | "A few cards to make it stick. Now it's not a pile of links. It's mine." | From curious to knowing. | Sources I understand. Cards to check. |
| 55.5–58.0 | end | ForeverLM window and lockup | "ForeverLM, for Mac." | ForeverLM for Mac | Private in your iCloud. |

About 134 words. The book is never said to have been found (Discover cannot list one): "I added my book". Beat 4's voice-over is true under route P1 and P2 alike.

The 42-second cut: beat 4 out; beat 1 4.5 s; beat 2 8 s ("I didn't know where to start, so I asked. It found a talk, an article, and said why."; the book step is left out); beat 3 6.5 s ("I paused the talk on the worm and asked what one sentence meant."); beat 5 8 s ("Now the real question. The answer cites the book, the talk and the paper, one click from the passage."); beat 6 8 s; beat 7 5 s ("A few cards to make it stick. Now it's not a pile of links."); end 2 s. 4.5 + 8 + 6.5 + 8 + 8 + 5 + 2 = 42.0 is the allocation (the 58-second film is 6 + 11.5 + 8.5 + 6 + 9 + 9 + 5.5 + 2.5); trim each beat to it in the edit from the cut lists under its camera map, never by speeding anything up.

## Recordly camera maps

Coordinates are percentages of the captured app window, measured from its top-left. `1.00×` is the full window. Recordly's zoom uses smooth ease-in-out without overshoot. The pointer finishes its move before the camera moves; the camera never chases a moving pointer.

**Contract** (the numbers below are layout targets; confirm each against take 1's raw frame and adjust by hand, the rules are what must hold):

- Never exceed `1.35×`.
- No zoom, push or pan without a pointer cause (the pointer has arrived at, hovered, selected or clicked the target). A push after a hard cut is the consequence of the click just before it.
- Hard cuts only on completed actions, and cut every wait (a search, an import, a model reply). Waits are cut, never sped up.
- Every new surface begins with a 350–500 ms full-window orientation shot before the camera moves closer. The 17-second hero is the one exception: it cuts onto a surface already framed at no more than `1.20×`.
- No crossfades between app actions.

Layout assumptions: the notebook is three columns, Sources about 0–27%, chat 27–73%, Studio 73–100%. The Studio column is collapsed (`studioCollapsed`) for beats 1–6, so the chat takes the width, and is open for beat 7. With the Reader open, the Reader is the left half and the chat the right.

### J1 — Curiosity (6.0 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.80 | `1.00×`, center `(50%, 50%)` | Completely still | The empty notebook, its name, and nothing else: empty on purpose. |
| 0.80–1.15 | `1.00× → 1.20×`, Sources search field `(13%, 13%)` | 350 ms ease-in-out | The pointer clicked into the field at 0.80; travel (0.20–0.80) had no camera move. |
| 1.15–4.15 | `1.20×`, field | Hold; the goal is typed at natural speed | The sentence is the story; typing is the one real-time action here. |
| 4.15–4.55 | `1.20×`, pan only to the chip row `(13%, 19%)` | 400 ms smooth pan, no scale change | The pointer moved to the Web chip. |
| 4.55–5.00 | `1.20×`, chip row | Hold; click Web at 4.70 | The click is settled before anything moves. |
| 5.00–6.00 | `1.20×`, field and chip | Hold | The typed goal and the chosen scope read together. Cut out at 6.00. Overlay 0.60–2.40. |

Film: the whole clip (6.0 s). The 42-second cut uses 0.20–4.70 (4.5 s).

### J2 — Where do I start? (12.0 s; the film uses 10.0 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.50 | `1.20×`, field `(13%, 16%)` | Hold; Return at 0.30 | Matches J1's last frame, so the two clips join on a still. |
| 0.50 | Results card at `1.00×`, center | Hard cut after the search | The wait is removed. |
| 0.50–0.95 | `1.00×` | Hold | Orientation: the card with its first rows. |
| 0.95–1.35 | `1.00×` | Hold; pointer to "N more", click at 1.35 | Opens the full list. |
| 1.50 | Full results list at `1.00×` | Hard cut on the completed click | The list is where the whys are readable. |
| 1.50–1.95 | `1.00×` | Hold | Orientation. |
| 1.95–2.35 | `1.00× → 1.20×`, rows 1–3 `(40%, 36%)` | 400 ms ease-in-out | The pointer is parked on the first row. |
| 2.35–4.35 | `1.20×` | Hold | Title, kind, site and the why line of the talk, podcast and article must be legible. |
| 4.35–4.75 | `1.20×`, pan only to the paper row `(40%, 64%)` | 400 ms smooth pan | The pointer travels to the paper's box. |
| 4.75–5.45 | `1.20×` | Hold; click to untick at 4.95 | The box clearing is the point: the hard paper waits. |
| 5.45–6.65 | `1.20×` | Hold | Let "later" land. |
| 6.65–7.05 | `1.20×`, pan only to the import control `(78%, 90%)` | 400 ms smooth pan | The pointer moves to Import. Click at 6.95. |
| 7.20 | Sources column at `1.00×` | Hard cut after the imports finish | The waits are removed. |
| 7.20–7.65 | `1.00×` | Hold | Orientation: the sources have landed. |
| 7.65–8.05 | `1.00× → 1.22×`, source list `(14%, 36%)` | 400 ms ease-in-out | The pointer is resting on the first row. |
| 8.05–10.45 | `1.22×` | Hold | Two-line titles, one icon treatment, no tick column; this is the "fill in" shot. |
| 10.45–10.85 | `1.22× → 1.06×`, center | 400 ms ease-out | Open the frame before the next beat. |
| 10.85–12.00 | `1.06×` | Hold | Overlay 0.60–2.80 over the card; end still. |

Film (about 8 s, then J2b's 3.5 s makes beat 2's 11.5 s): drop 1.50–1.95, 2.35–3.00, 3.35–4.35, 5.45–6.05 and 10.85–12.00 (3.85 s). The 42-second cut keeps those 8 s and leaves J2b out.

### J2b — From my library (5.0 s; the film uses 3.5 s)

Discover never lists a book, so the learner's own book is filed from the library, in the same Sources field, after the web sources have landed. It is shot from checkpoint S1 and cut in after J2's landed-rows shot.

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.40 | `1.06×`, Sources column | Hold | Orientation: the landed rows. |
| 0.40–0.80 | `1.06× → 1.20×`, field and scope chips `(13%, 16%)` | 400 ms ease-in-out | The pointer has clicked the Library chip. |
| 0.80–2.00 | `1.20×` | Hold; the title typed (about 0.7 s) | |
| 2.00 | Library results at `1.20×`, `(14%, 34%)` | Hard cut after the search settles | The book's row with its cover. |
| 2.00–3.40 | `1.20×` | Hold; the pointer ticks and adds at 2.60 | |
| 3.40 | Sources column with the book landed at `1.06×` | Hard cut after the add | The book is one row among the others. |
| 3.40–5.00 | `1.06×` | Hold | The notebook's rows read as one set. |

Film (3.5 s): drop 0.00–0.40, 2.80–3.40 and 4.60–5.00 (1.4 s).

### J3 — Watch the easy one first (11.0 s; the film uses 8.5 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.25 | `1.06×`, source list | Hold; click the talk's row at 0.10 | The click is the cause of the cut. |
| 0.25 | Reader open at `1.00×`, center | Hard cut on the opened Reader | Video left, transcript right. |
| 0.25–0.70 | `1.00×` | Hold | Orientation. |
| 0.70–1.10 | `1.00×` | Hold; the pointer travels to the player's pause control | Cause before camera. |
| 1.10–1.50 | `1.00× → 1.18×`, player `(25%, 42%)` | 400 ms ease-in-out | The pointer is on the control. |
| 1.50–2.35 | `1.18×` | Hold; pause at 1.65 | The worm frame. |
| 2.35–2.75 | `1.18×`, pan only to the transcript `(75%, 46%)` | 400 ms smooth pan | The pointer moves to the sentence and begins the drag at 2.75. |
| 2.75–4.05 | `1.18×` | Hold; the drag ends at 3.35; the selection bar appears | The selected sentence and its bar read together. |
| 4.05 | Chat with the quote chip at `1.00×` | Hard cut on the Chat click | The chat opens on the right with the passage staged. |
| 4.05–4.50 | `1.00×` | Hold | Orientation. |
| 4.50–4.90 | `1.00× → 1.20×`, composer `(66%, 86%)` | 400 ms ease-in-out | The pointer is in the composer. |
| 4.90–6.70 | `1.20×` | Hold; the question typed ("What does that mean? Does the article say the same?"); Return at 6.45 | Typing is real time. |
| 6.70 | Finished answer at `1.00×` | Hard cut after the reply | The wait is removed. |
| 6.70–7.10 | `1.00×` | Hold | Orientation. |
| 7.10–7.55 | `1.00× → 1.16×`, answer `(66%, 42%)` | 450 ms ease-in-out | The consequence of the send. |
| 7.55–10.00 | `1.16×` | Hold | Two cited sources, the quote above the question. Overlay 0.40–2.20. |
| 10.00–11.00 | `1.16× → 1.04×` | 450 ms ease-out, then hold | End still. |

Film (8.5 s): drop 0.70–1.10, 5.60–6.20, 7.55–8.05 and 10.00–11.00 (2.5 s). The 42-second cut (about 6.5 s) also drops 0.25–0.70 and 4.05–4.50 and ends at 8.50.

### J4 — Take it with you (8.0 s; dropped from the 42-second cut)

Route P1 (the episode filed as its YouTube video) and route P2 (the static transcript) share this map; only the 1.10–3.10 hold differs.

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.25 | `1.06×`, source list | Hold; click the episode's row at 0.10 | The cause of the cut. |
| 0.25 | Reader on the episode at `1.00×` | Hard cut on the opened Reader | |
| 0.25–0.70 | `1.00×` | Hold | Orientation. |
| 0.70–1.10 | `1.00× → 1.20×`, transcript `(72%, 46%)` | 400 ms ease-in-out | The pointer rests on the transcript. |
| 1.10–3.10 | `1.20×` | Hold. P1: the highlighted line follows playback (real time). P2: the pointer scrolls the transcript slowly. | The beat's picture. |
| 3.10–3.60 | `1.20×` | Hold; the drag selects a line | |
| 3.60–4.10 | `1.20×` | Hold; the selection bar; click Chat at 3.90 | |
| 4.10 | Chat with the quote chip at `1.00×`, then the answer after the typed question | Hard cut on the Chat click; a second hard cut after the reply (the typing and the wait are cut) | |
| 4.10–6.10 | `1.00× → 1.16×`, answer `(66%, 42%)` after the cut | 450 ms ease-in-out | The consequence of the send. |
| 6.10–8.00 | `1.16×` | Hold | The answer names the episode and the talk. Overlay 0.60–2.40. |

Film (6.0 s): drop 2.10–3.10 of the hold and 7.00–8.00 (2.0 s). Dropped from the 42-second cut.

### J5 — Now the real question (12.0 s; the film uses 9.5 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.40 | `1.00×`, Sources column and the kept Discover list | Hold | The paper row is still unticked in the list that survived. |
| 0.40–0.80 | `1.00×` | Hold; the pointer travels to the paper's box | Cause before camera. |
| 0.80–1.20 | `1.00× → 1.20×`, paper row `(40%, 64%)` | 400 ms ease-in-out | |
| 1.20–2.05 | `1.20×` | Hold; tick at 1.25; Add at 1.80 | |
| 2.20 | Sources column with the paper landed at `1.20×` | Hard cut after the import | A PDF in, no "PDF needed" badge. |
| 2.20–2.70 | `1.20×` | Hold | |
| 2.70 | Chat, composer pre-typed, at `1.00×` | Hard cut | |
| 2.70–3.10 | `1.00×` | Hold | Orientation. |
| 3.10–3.45 | `1.00× → 1.22×`, composer `(50%, 86%)` | 350 ms ease-in-out | The question reads in full. |
| 3.45–3.85 | `1.22×` | Hold; Send at 3.60 | |
| 3.95 | Finished answer at `1.00×` | Hard cut on the click | Latency is cut. |
| 3.95–4.35 | `1.00×` | Hold | Orientation. |
| 4.35–4.80 | `1.00× → 1.16×`, first paragraph `(50%, 40%)` | 450 ms ease-in-out | |
| 4.80–6.90 | `1.16×` | Hold | Read; the chips and the Sources footer name three kinds. |
| 6.90–7.35 | `1.16× → 1.30×`, the book citation `(54%, 66%)` | 450 ms ease-in-out | The pointer arrived at the chip during 6.50–6.90. |
| 7.35–7.65 | `1.30×` | Hold; click at 7.45 | The click finishes at the same scale. |
| 7.75 | Reader beside the answer at `1.00×`, center | Hard cut after the Reader opened | The flash starts here and fades by about 11.35. |
| 7.75–8.30 | `1.00×` | Hold | The relationship between answer and source. |
| 8.30–8.75 | `1.00× → 1.24×`, the passage `(26%, 50%)` | 450 ms ease-in-out | |
| 8.75–11.30 | `1.24×` | Hold | The proof moment; the pointer does not move. Overlay 7.75–11.20. |
| 11.30–12.00 | `1.24× → 1.00×`, center | 450 ms ease-out | Close the beat. |

Film (about 9.5 s): drop 0.00–0.80, 2.20–2.70, 5.60–6.30 and 11.30–12.00 (2.7 s). The 42-second cut (about 8 s) also drops 0.80–1.20 of the paper's push, 3.95–4.35 and 8.30–8.75.

### J6 — Do I really get it? (12.0 s; the film uses 9.5 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.40 | `1.00×`, empty chat guide | Hold | Only the worm sources are ticked. |
| 0.40–0.80 | `1.00× → 1.20×`, the "Quiz me on it" chip `(50%, 60%)` | 400 ms ease-in-out | The pointer is on the chip; click at 1.00. |
| 1.15 | Review chat at `1.00×` | Hard cut after the first turn | The "Review plan" and the first question. The wait is cut. |
| 1.15–1.60 | `1.00×` | Hold | Orientation. |
| 1.60–2.00 | `1.00× → 1.18×`, first question `(50%, 36%)` | 400 ms ease-in-out | |
| 2.00–3.00 | `1.18×` | Hold | The question is short and readable. |
| 3.00 | Composer, `1.20×`, the shaky explanation being typed | Hard cut | A short first try ("Cells are like batteries and the voltage makes the head."). |
| 3.00–5.20 | `1.20×` | Hold; typed; Send at 5.10 | Typing is real time. |
| 5.40 | The tutor's reply at `1.18×`, paragraph `(50%, 46%)` | Hard cut after the reply | The wait is cut. |
| 5.40–8.00 | `1.18×` | Hold | The prose that says what is missing: never cut below 2.5 s. |
| 8.00 | The second explanation and the tutor's verdict at `1.00×` | Hard cut after the second turn | The typing and the wait are cut; the learner's second message stays visible above the reply. |
| 8.00–8.40 | `1.00×` | Hold | Orientation. |
| 8.40–8.80 | `1.00× → 1.18×`, reply `(50%, 48%)` | 400 ms ease-in-out | |
| 8.80–11.60 | `1.18×` | Hold | "It landed." Overlay 0.60–2.40 and 8.80–11.40. |
| 11.60–12.00 | `1.18× → 1.06×` | 350 ms ease-out | |

Film (9.5 s): drop 0.00–0.40, 2.30–3.00, 8.00–8.40 and 11.00–12.00 (2.5 s); the tutor's gap paragraph keeps its full 2.6 s. The 42-second cut (about 8 s) also drops 1.15–1.60, 8.40–8.80 and 11.00–11.60 of the verdict hold.

### J7 — Make it stick, then step back (8.5 s; the film uses 6.0 s)

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.40 | `1.00×`, chat | Hold; composer holds "Make three cards from this." | |
| 0.40–0.80 | `1.00× → 1.20×`, composer `(50%, 86%)` | 400 ms ease-in-out | Send at 1.00. |
| 1.15 | The three-card deck at `1.00×` | Hard cut after the model call | The wait is cut. |
| 1.15–1.60 | `1.00×` | Hold | Orientation. |
| 1.60–2.00 | `1.00× → 1.18×`, Keep All `(60%, 58%)` | 400 ms ease-in-out | The pointer is on the button; click at 2.30. |
| 2.00–2.70 | `1.18×` | Hold | The state changes to kept. |
| 2.85 | Notebook whole at `1.00×`, Studio open, the Cards row showing | Hard cut after the Studio opened | Sources, chat and the Cards row in one frame. |
| 2.85–3.30 | `1.00×` | Hold | Orientation. |
| 3.30–3.70 | `1.00× → 1.18×`, Cards row `(87%, 60%)` | 400 ms ease-in-out | The pointer is on the row. |
| 3.70–5.00 | `1.18×` | Hold | "3 kept · due · to check". |
| 5.00 | Notebook whole at `1.00×` | Hard cut | |
| 5.00–5.50 | `1.00× → 1.08×`, title and sources `(37%, 30%)` | 500 ms very gentle push | A confident hold, not another reveal. |
| 5.50–8.50 | `1.08×` | Hold | The pointer is parked outside the window. Overlay 5.20–8.50. This is the home pose. |

Film (6.0 s): use 1.15–2.70, 3.30–5.00 and 5.00–7.75. The 42-second cut (about 5 s) drops 1.15–1.60 and the first 0.5 s of the last hold.

### The 17-second hero

The first and last frames are the **home pose**: J7's final frame, the Bioelectricity notebook whole at `1.08×`, anchored `(37%, 30%)`, five sources, the cited answer in the chat, the Cards row. The loop opens on where the story ends, cuts back to where it began, runs the journey, and returns to that exact frame.

| Time | Scale and focus | Motion | Reason |
|---|---|---|---|
| 0.00–0.60 | `1.08×`, title and sources `(37%, 30%)` | Completely still | Identify ForeverLM and the notebook before anything moves. |
| 0.60 | J1's last state at `1.20×`, field and chip `(13%, 16%)` | Hard cut | Rewind to the start. The goal is already typed and Web chosen. |
| 0.60–1.30 | `1.20×` | Hold; Return at 1.30 | Overlay "I want to understand this." 0.70–2.30. |
| 1.55 | Results list at `1.00×` | Hard cut after the search | The wait is cut. |
| 1.55–2.00 | `1.00×` | Hold | Orientation; the pointer is travelling to the paper's box. |
| 2.00–2.35 | `1.00× → 1.20×`, paper row `(40%, 64%)` | 350 ms ease-in-out | The pointer has arrived at the box. |
| 2.35–3.25 | `1.20×` | Hold; untick at 2.65 | The hard paper waits. Overlay "It finds where to begin." 2.40–4.60. |
| 3.25 | Landed sources at `1.20×`, list `(14%, 36%)` | Hard cut after the imports | |
| 3.25–4.65 | `1.20×` | Hold | Titles, covers or icons, and the podcast row are readable. |
| 4.65 | Reader on the talk at `1.00×` | Hard cut | |
| 4.65–5.10 | `1.00×` | Hold; the pointer drags the selection | Orientation, with the cause underway. |
| 5.10–5.45 | `1.00× → 1.20×`, the selected sentence `(75%, 46%)` | 350 ms ease-in-out | The drag finished at 5.10. |
| 5.45–6.85 | `1.20×` | Hold; click Chat at 6.60 | Overlay "Ask while you watch." 4.80–6.50. |
| 6.85 | Answer in the chat at `1.16×`, `(66%, 42%)` | Hard cut after the reply | |
| 6.85–8.15 | `1.16×` | Hold | Two cited sources and the quote. |
| 8.15 | Composer, question pre-typed, at `1.00×` | Hard cut | |
| 8.15–8.55 | `1.00×` | Hold | Orientation. |
| 8.55–8.90 | `1.00× → 1.22×`, composer `(50%, 86%)` | 350 ms ease-in-out | |
| 8.90–9.30 | `1.22×` | Hold; Send at 9.05 | |
| 9.30 | Finished answer at `1.08×`, `(50%, 44%)` | Hard cut on the click | Latency is cut honestly. |
| 9.30–9.70 | `1.08× → 1.18×`, first paragraph `(50%, 40%)` | 400 ms ease-in-out | |
| 9.70–11.20 | `1.18×` | Hold | The answer, with the three source kinds' chips. |
| 11.20–11.60 | `1.18× → 1.30×`, the book citation `(54%, 66%)` | 400 ms ease-in-out | The pointer arrived during 10.80–11.20. |
| 11.60–11.90 | `1.30×` | Hold; click at 11.75 | |
| 11.90 | Reader beside the answer at `1.00×` | Hard cut after the Reader opened | The flash starts and fades by about 15.5. |
| 11.90–12.35 | `1.00×` | Hold | |
| 12.35–12.75 | `1.00× → 1.24×`, the passage `(26%, 50%)` | 400 ms ease-in-out | |
| 12.75–14.95 | `1.24×` | Hold | The proof. Overlay "Every claim opens its source." 11.60–14.80. |
| 14.95 | Home pose at `1.00×`, center | Hard cut | Return to the opening world. |
| 14.95–15.35 | `1.00×` | Hold | |
| 15.35–15.85 | `1.00× → 1.08×`, title and sources `(37%, 30%)` | 500 ms very gentle push | |
| 15.85–17.00 | `1.08×` | Hold | Overlay "From curious to knowing." 15.10–17.00; the "ForeverLM for Mac" lockup bottom-right 15.50–17.00; the pointer hidden. |

The last frame is the first frame: same scale, same anchor, same sources, same chat. Record the home pose once (J7) and use that master for both ends; record the middle from a duplicate take of the journey.

## Atomic capture list

Capture each clip as its own project, three takes (deliberate, natural, fast), a one-second hold at each end.

| ID | Length | Action | What must be readable | Shares with |
|---|---:|---|---|---|
| J1 | 6 s | Empty notebook named Bioelectricity; the goal typed in the Sources field; Web chosen | The notebook name, "No sources yet", the full goal (as a burned caption if the field scrolls it) | Film 1, hero 0.60 |
| J2 | 12 s | Return; the results list; untick the paper; import; the sources land | For each of the talk, podcast and article: its kind, title (two lines) and the why line; the unticked paper; the landed rows | Film 2, hero 1.55–4.65 |
| J2b | 5 s | Search the library for the book and add it | The book's title and cover in the library results; the five rows in the Sources column | Film 2 (after J2) |
| J3 | 11 s | Open the talk; pause on the worm; select a sentence; Chat; the question; the answer | The worm frame, the selected sentence, the quote chip, the question, an answer citing two sources | Film 3, hero 4.65–8.25 |
| J4 | 8 s | Open the episode; read or watch along; select a line; Chat; the answer | The episode's title and transcript, the selected line, an answer naming the episode and the talk | Film 4 |
| J5 | 12 s | Add the paper; send the question; the cited answer; open the book citation | Three cited kinds; the book's title; the highlighted passage in the Reader beside the answer | Film 5, hero 8.25–14.95, poster |
| J6 | 12 s | Quiz me on it; a shaky explanation; the tutor's gap feedback; the second explanation; the verdict | The Review plan, both explanations, the sentence that says what is missing, the verdict | Film 6 |
| J7 | 8.5 s | Make three cards; keep them; the notebook whole | Three cards' prompts, the Cards row line, the sources, the chat | Film 7, hero 0.00 and 15.35 |

**Checkpoints, so a retake never repeats the paid steps before it:** S0 an empty notebook (J1); S1 after the web sources landed and processed (J2 done, transcript and covers settled); S1b the book filed (J2b); S2 the paper added (J5's first seconds). J3, J4, J5, J6 and J7 are re-taken from S2 by starting a New chat each time and deleting the previous take's chat and cards. The paper's import and the cards are one-shot: delete and re-add them for a retake.

## Recordly preset

- Capture one app window at a time, never the whole desktop.
- Source capture: Retina, 2456×1380 or higher, 60 fps. Light mode.
- Composition: 16:9, exported master at 1920×1080; website derivative at 1280×720, 30 fps, H.264 fast-start.
- Window scale roughly 88–92%, with 56–64 px of breathing room.
- Background: quiet mint/lilac/coral gradient matching the homepage (`tahoe-light.jpg` where a photograph is needed); no wallpaper.
- Corner radius 18–22 px; soft, restrained shadow.
- Cursor 1.25–1.35×, medium smoothing, subtle click bounce, low motion blur.
- Zooms: manual, after capture, 1.18–1.35×, 350–500 ms easing.
- No webcam. No microphone for atomic masters. Record the narration separately.
- Remove waits; cut to the finished output instead of accelerating a spinner. No crossfades between app actions.

## Staging a from-scratch take

The take is made in the Dev build from the approved branch (never the production app while a feature is unreleased). Nothing filmed is the learner's real library: Screen record mode narrows the window to what the take makes.

1. **Screen record mode, per take.** Turn it off and on at the start of every take so the cutoff is now: everything the previous take made falls before it and stays off screen. Settings (over MCP: `recording.*`): `screen_record_mode` on; `notebook_id` none (the take has no curated notebook); `library_sources` off; `meeting_group_ids` empty (no beat uses a meeting, so the seminar folder is no longer allow-listed); `image_ids` empty; `source_ids` only the book's chapters (below). The mode never appears in the window: the composer draws no model chip, the Studio column draws no floating Add note pill, no row carries a date older than the take, "Select all" and the tick boxes appear only when a source is left out or under the pointer.
2. **A throwaway notebook per take**, created during the take (J1), renamed Bioelectricity before the first source so ForeverLM leaves the name alone. A notebook made during the take shows with its chats, Goals, Pages, cards and Ideas (all made after the cutoff). Do not file anything into the curated showcase notebook.
3. **Sources must be real, public and not already in the library**, so "it arrives" is honest. Before the shoot, check each candidate's address against the library (Discover marks a row "In library"); a row that carries the badge is out. A source the library already holds stays off screen even when filed into the take notebook (its old date keeps it hidden, so the learner's other reading cannot leak), so a badge also means the row would vanish from the notebook. Use: a talk not among those already filed in the showcase notebook, a public Apple Podcasts episode with a transcript (route P2) or one that also has a YouTube version (route P1), an article from an outlet not yet in the library, and one open-access paper whose PDF lands without a prompt.
4. **The book is the one source that comes from the learner's library.** Discover never lists books, and the library already holds the book: file it from the Sources search field's Library scope rather than Discover, and say "I added my book" in the voice-over, never "it found the book". Because its old date would hide it, list every chapter id on `recording.source_ids` (a kept source shows while public, so it can be found to be filed). If that is not wanted, replace the book beat's citation with a chapter-sized article.
5. **Make Discover repeatable enough; live discovery is the intent.** "Pre-generate once" no longer means pre-baked results (the notebook is empty at the start, and the film is the product doing it). It means: rehearse the whole journey once off camera in a scratch take to (a) learn which wording of the goal returns the five kinds, (b) learn how long a search, an import, a transcript and an answer take, (c) check every import succeeds (a podcast host that stages "Is this the right podcast?" or errors is out), and (d) read the app's cost line for one take. On camera, use the same wording, and re-take (delete the take and start again) until the first rows hold the talk, the podcast, the article and the paper with sensible whys and no importer errors. Pick the best take of each beat; do not splice rows from different searches into one frame.
6. **Order of capture**: J1 and J2 first, in real time, then wait off camera until the transcripts and covers have settled (an Apple transcript is held back until formatting finishes, minutes for a long episode). Then J3, J4, J5 (paper added), J6, J7, each from its checkpoint, cutting waits in the edit.
7. **After every take, delete what it made**: list the take's sources before deleting the notebook (`list_notebook_sources`), then delete the notebook, those sources (never the kept book chapters), its chats, Pages, cards and goal. A take's sources left behind would show "In library" in the next take's Discover and break the arrival. The mode shows only the take's own items, so a list made with the mode on is the deletion list.
8. Studio column: collapsed for beats 1–6, open for beat 7. Sidebar hidden, greeting pane and Library pane closed, no account or credits row, light mode, a fixed 16:9 window wide enough that the Reader keeps video and transcript side by side (about 708 pt of Reader width).
9. Use a fresh browser profile if a browser is ever on screen (the secondary clips only). Disable notifications, menu-bar distractions and the Dock. Do Not Disturb. Mute the output before a take that plays media.
10. Review every raw take frame by frame for private names, other notebook titles, account avatars, URLs and notification remnants before editing.

## Overlay system

The overlay is the beat's story line; the caption is a second line in the script table.

- **I want to understand this.**
- **It finds where to begin.**
- **Ask while you watch.**
- **Listen anywhere. It all connects.**
- **Every claim opens its source.**
- **Say it yourself. Find the gaps.**
- **From curious to knowing.**

Maximum six words each. One weight, sentence case, bottom-left, 5% safe margin, held at least 1.4 s, never over the action. The film may also use "Private in your iCloud" and the "ForeverLM for Mac" lockup. The hero uses five of the seven (not 4 and 6).

## Acceptance gate

None of the cuts ships until all are true:

- A muted first-time viewer can say "I want to learn something; it finds sources, answers with evidence from them, and checks that I understood" after one pass of the film, and "it connects my sources and answers with evidence" after one loop of the hero.
- ForeverLM itself is visible in every frame and the first frame is the product (hero: at least 80% of the runtime, in practice all of it).
- Everything on screen was made during the take: no dated row older than the take, no other notebook, chat, Page, meeting or account.
- No source appears that the library already held, except the book, which is shown as coming from the learner's library.
- At least two source kinds support an answer on screen; one citation opens to an exact, readable, highlighted passage during the hold.
- The first try in the review is visibly incomplete and the tutor's sentence about what is missing is readable for at least 2.5 s.
- No text essential to the story is smaller than about 16 px in the 1280×720 derivative.
- No loading spinner, empty state (other than J1's, on purpose), accidental scroll, pointer hunt or dead air survives the edit; no model chip, price, Add note pill or row of identical ticks is visible.
- Nothing is sped up; every wait is a cut.
- The poster frame is meaningful alone.
- The hero's final frame is its first frame; the hero is under roughly 5 MB where quality permits, respects reduced motion, and has a static poster fallback.

## Production order

1. Rehearse the whole journey once off camera (Staging 5). Settle the goal's wording, the candidates and the cost.
2. Capture J1–J7 in the order above, then assemble a rough 58-second film with no styling.
3. Watch it muted at the size of the homepage, once. If the question → sources → answer → evidence → "I can say it" chain is not obvious, reshoot before polish.
4. Apply the Recordly preset, the camera maps and the overlays.
5. Export the 17-second hero and the poster; test desktop and mobile crops; check the loop.
6. Record the narration and finish the 58-second film and the 42-second cut.
7. Derive the 24-second social cut last (3 s of J1, 7 s of J2, 4 s of J3, 7 s of J5, 3 s of J7); do not let social pacing compromise the website version.

## Open decisions for the product owner

- Beat 4: build a podcast player (a playhead in `TranscriptReaderViews.swift`), film an episode that has a YouTube version, or film the transcript read-along and drop "plays".
- Beat 6: accept the tutor's prose as "what is missing", or give the review a gap card (`Prompts.reviewTutor`, `ReviewChatComponents.swift`).
- Beat 7: give a notebook a goal state, or end on sources and cards.
- Discover: group rows by kind and give them covers, and add a book kind, or keep the flat list and say the kinds in the caption.
- The book: file it from the library (kept on `recording.source_ids`), or replace it.
