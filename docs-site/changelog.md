# Changelog

All notable changes to ForeverLM are documented here. Dates are in YYYY-MM-DD format.

ForeverLM follows [semantic versioning](https://semver.org) against its public surface: the MCP tool contracts, the knowledge-base/sync format, and licensing compatibility. While the version is 0.x, minor releases may include breaking changes to that surface; patch releases never do.

## Unreleased

- **The Library no longer has a Not in any notebook button.** The toggle beside the search, and the filter it switched on, are gone.
- **A card for the sources that have no cards.** The "Cards to check" card in the corner also counts the sources in your library that no card covers, read or not: "5 sources have no cards yet", with **Make Cards**, which opens the sheet for all of them together so the cards can link the ideas they share. With nothing to check, the card is titled "Sources without cards". It follows the same switch, Say when drafted cards wait.

## 0.157.0 (build 237) — 2026-10-15

**Highlights:**
- **Panes:** each pane's top-right corner swaps what it shows, and dropping a place onto a pane replaces it.
- **Cards:** a card can play a saved animation, reads math, and the chat adds a picture to the previous card at once.
- **Copy Conversation** works on every chat.

- **A card can show an animation.** A card's question or answer can carry one of your saved animations, which plays inline under the card's pictures, with its own controls, on the Mac and the iPhone, in Review, To Check and the Knowledge Map's review; an answer's animation stays hidden until the answer shows. It runs sandboxed, with scripts and no network. Assistants put it on a card with `update_card`, `triage_cards` or `save_card_drafts`, by passing the animation's `foreverlm-site://<animation_id>/` address in `front_images` or `back_images` (one per face).
- **Cards can carry math.** A formula or symbol written in LaTeX (`\(…\)` or `$$…$$`) on a card's question, answer or why now reads as math on the Mac and the iPhone (`k_{-1}` as k₋₁, `\frac{a}{b}` as a/b) instead of showing backslashes and braces, and the card writers use it when a card needs a formula.
- **A pane's corner changes what it shows.** Hover a pane and the icons at its top right (Chat, Library, Memory, Browser, Pages) swap what the pane shows; a narrow pane folds them into one menu, and each icon can be dragged to another pane.
- **Drop a place onto a pane to replace it.** Drag a sidebar row, a Space place or New chat onto the middle of a pane and that pane shows it; the edges still open it beside.
- **Add it to the card, even after you moved on.** Ask the chat to put a figure on the previous card and it does, whether you kept that card or it is still waiting in To Check, without asking again.
- **Cards read math.** Formulas on a card read as math, not as raw LaTeX.
- **Copy Conversation everywhere.** Copy Conversation is in the menu bar, the command menu, with ⇧⌘C, and on every chat's sidebar row.
- **Chat points at passages in notes and transcripts.** The chat can open a meeting's notes or a podcast's transcript at the passage it cites.
- **【Title】 citations are links.** A bracketed title in a reply becomes the source's link.
- **Shorter card answers.** Card writers ask what an idea means and answer in one short sentence, and never ask what a source does not claim.
- **Settings General is one column.** One row per setting, labels on the left and the controls in a single column on the right.
- **OpenRouter logo on your own key.** The account menu's own-key row shows the OpenRouter logo.

## 0.156.0 (build 236) — 2026-10-15

**Highlights:**
- **Make me plan:** an option that opens the planning chat by itself each morning and keeps the card until the day is planned.
- **Cards:** a picture can be added to the card you are checking, no more easy/medium/hard label, and the Why reads as part of the answer.
- **To Check:** the iPhone asks before it shows the answer.
- **Show Passage** opens a recording at the words; **AI Usage** sits under the OpenRouter button.

- **Add a picture to the card you are checking.** Ask the chat beside To Check to add a figure it showed ("can you add it to the card?") and the picture goes on the card in front of you. It waits with the card: Keep carries it, Skip drops it. Assistants do it with `update_card` and `back_images` (or `front_images`) on a card still to check.
- **Cards no longer say easy, medium or hard.** A model used to guess a difficulty when it drafted a card and the card wore it, a small MEDIUM over the question, in To Check, in the review and in the deck a chat shows. That guess said nothing about how you find the card, so it is gone, on the Mac and the iPhone, and nothing asks for it any more (`save_card_drafts` and `save_mnemonic_reading` no longer take a `difficulty`). How hard a card is for you is something your answers will show over time.
- **Why the answer holds reads as part of the answer.** On the back of a card it is now one plain sentence under the answer, without the small WHY label, on the Mac's review, To Check and All Cards, on the iPhone, and in Edit Card. Drafted cards are asked to give the cause or the evidence that makes the answer true, not the answer again or what the author did.
- **Make me plan.** Settings → General → Day has a new switch. On a morning when your calendar holds nothing you planned, the planning chat opens by itself the first time you are at your Mac, and the "Plan your day" card cannot be closed or hidden until the calendar holds a plan of yours. Off by default; assistants read and set it as `force_planning_the_day`.

- **AI Usage is under the OpenRouter button.** The sidebar's OpenRouter button opens AI Usage beside what is running now.
- **Show Passage opens at the words.** From a video, podcast or meeting, Show Passage opens the recording at the passage, not at its start.
- **To Check asks before it answers, on the iPhone too.** The iPhone's To Check shows the question and waits for your answer before the back; on the Mac the answer field keeps the keys until the back shows.
- **The morning banner suggests cards for what you added.** It also offers cards for what you added to the library that day.
- **Chat sources are links.** The chat cites a source only as a link, never as a bracketed number with an id; and a bare "this" or "that" beside a card is answered from the previous reply and the card together.
- **Better card openers.** The walk and quiz writers stop opening cards with "In this paper", "In this lecture" or "In this course".

## 0.155.0 (build 235) — 2026-10-15

**Highlights:**
- **Cards on every source that prints them:** one card stands on both sources, and its question has one answer.
- **Edit Card, Copy Card ID, Draw Picture:** the editor is the card itself; a figureless card gets a diagram.
- **Plan my day:** a chat that proposes the day at once and revises as you answer.
- **No unattended AI:** the evening day close and every pass that ran on its own are gone.

- **Draw Picture on a card to check**: a card from a podcast or article, which has no figure to show, can be given a diagram of its answer from the ••• over the card. It is drawn only when you choose it, and kept if you keep the card.
- **The evening day close is gone,** with its "Close the day at" setting and the `close_day` tool. ForeverLM no longer runs AI in the background at the end of the day: no folding chats into understanding documents, no idea extraction, no background card drafting or rewording, no notes written from your day, and no re-checking of kept cards. Cards still draft as you finish a source when that switch is on, and the notes you add yourself stay.

## 0.154.0 (build 234) — 2026-10-14

**Highlights:**
- **Lay Out the Talk:** a video's slides on a canvas as a storyboard, with the papers each slide cites hung under it.
- **Cited on this slide:** a slide's inspector places or adds the papers read off it.
- **Canvas fixes:** notes land where you typed them, Undo stays yours, and assistants no longer move what you placed.

## 0.153.0 (build 233) — 2026-10-14

**Highlights:**
- **Speaking to a canvas uses your Dictation model,** the one chat uses, so it hears you better.
- **The bar shows each step** as the canvas carries out your request.

## 0.152.0 (build 232) — 2026-10-14

**Highlights:**
- **Keep or set aside what Ask suggests, by speaking** ("keep the first two").
- **Speaking to a canvas understands more:** words under a card, a page turned, a note told from a paper.

## 0.151.0 (build 231) — 2026-10-14

**Highlights:**
- **Speaking to a canvas is steadier:** it waits for your library at launch, retries a failed request at once, and its bar says what it did.
- **Tidy Up makes room** without piling cards onto others.

## 0.150.0 (build 230) — 2026-10-14

**Highlights:**
- **Speaking to a canvas puts things where you say** ("below the Mitophagy region", "between the two regions") and keeps the canvas tidy.
- **Tidy Up makes room** instead of covering cards.

## 0.149.0 (build 229) — 2026-10-14

**Highlights:**
- **Speak to a canvas (beta):** hold S, say what to change, and it changes about a second after you let go.
- **A paper reads the moment it is added**, its cleanup running in the background.

## 0.148.0 (build 228) — 2026-10-13

**Highlights:**
- **ForeverLM works like Codex where the two share a surface.** Pages, the chat, the Space, Plugins and the keyboard now follow Codex first, with ForeverLM's own features on top.
- **Pages:** Codex's slash menu and selection bar, Copy link on a block, the page's headings at its edge, comments on the words in threads, page activity beside the page, and Ask for change written into the page with Accept and Undo.
- **Chat:** `@` finds sources, Pages, chats and notebooks; Try Again, Edit, Find in chat, a queue you can manage, drafts kept across a quit, and Codex's thread commands.
- **A command menu (⌘K or ⇧⌘P)** and Codex's keyboard shortcuts, listed with ⌘/.
- **The Space:** choose several things at once, search inside pages, sort by last activity, and spaces go to Trash.
- **Plugins** reads as Codex's, with your skills in a Skills tab beside it.

## 0.147.0 (build 227) — 2026-10-13

**Highlights:**
- **The chat shows what is open beside it**, and a × leaves a source out.
- **A + on the icon strip starts a new chat**, and any Space place can be dragged onto the strip to stay there.
- **A book reads the moment you add it.** A PDF or EPUB book opens whole at once; its details and chapters are found in the background, and what you mark and where you read to meanwhile move to its chapter.
- **An ebook PDF is never treated as a scan**, so a picture cover no longer sends pages to OCR proofreading.
- **A text file or dropped text is in your library at once**, under its own name; its title follows.
- **A Reader window shows a web page while it is fetched**, as the Reader beside the library does, instead of a spinner.
- **A podcast transcript reads the moment it is fetched**, laid out in paragraphs; speaker names and formatting follow in the background, two episodes at a time, and survive a quit.

## 0.146.1 (build 226) — 2026-10-13

**Highlights:**
- **Typing straight after Return in a list keeps every letter**, where the first ones were scrambled.
- **Empty lines are stored as blank lines**, not `<br />`.

## 0.146.0 (build 225) — 2026-10-13

**Highlights:**
- **Writing in a Page is smoother**: the Mac's own caret, nothing typed is ever taken back, ⌘Z stays in the page, and the caret stays put when a teammate's edit or a picture arrives.
- **Edit with AI shows its proposal as the page will**, with the changes marked and a passage's sources kept out of sight.
- **Pasting behaves**: pictures are kept, a PDF quotation becomes paragraphs, an article's citation numbers become footnotes.

## 0.145.0 (build 224) — 2026-10-12

**Highlights:**
- **A book is one file**: a PDF or an EPUB is kept as itself, and books split by earlier builds are put back together on the first launch.
- **Every paid background step has a Stop**, and a stop lasts until Resume.
- **Add Book reads scanned PDFs** and takes several books at once.

## 0.144.0 (build 223) — 2026-10-12

**Highlights:**
- **To Check deals a card at a time**, with Skip, Edit and Keep under it.
- **Chat answers much sooner**: a request carries the everyday tools and loads the rest when it needs them.
- **Explainer and Feynman Technique take podcast episodes**, not only papers.

## 0.143.4 (build 222) — 2026-10-12

**Highlights:**
- **A notebook's Sources column reads like NotebookLM's**: one line a source, the kinds as words.
- **An empty notebook's column says what to do** in Library, Web and PubMed.

## 0.143.3 (build 221) — 2026-10-12

**Highlights:**
- **A hover is a lighter grey than a selection.**
- **A notebook's Sources column shows the Library itself**, to drag from or search.
- **Studio's tiles put the word beside the icon.**

## 0.143.2 (build 220) — 2026-10-12

**Highlights:**
- **Every list in the Space is laid out the same way**: its name, the search, one pill named for what it holds, and the same row of filters.
- **Start Pomodoro Timer… asks what the session is for**, and names the session after it.

## 0.143.1 (build 219) — 2026-10-12

**Highlights:**
- **New menus are a card with a glyph on every row**, grouped and spaced like Codex's.

## 0.143.0 (build 218) — 2026-10-12

**Highlights:**
- **The top left is the traffic lights, ‹ › and the sidebar toggle.** ‹ › go back and forward through the places a window showed.
- **The icon strip keeps shortcuts.** Its ⋯ opens any place and keeps the ones you use on the strip; the strip itself never folds.
- **An empty canvas is somewhere to drop things**, with the Library beside it.
- **The Reader's ‹ goes back to the Library or Space it covered.**
- **Podcasts played in Apple Podcasts count as listening** on the day they were played.

## 0.142.1 (build 217) — 2026-10-12

**Highlights:**
- **Screen record mode keeps the model chip.** The mode chooses what a recording shows and hides your name (a stand-in, Richard, takes its place); what the app can do stays the same.
- **Fetching many transcripts at once no longer crashes ForeverLM.**
- **Podcasts with a transcript are no longer listed as having no text yet.**

## 0.142.0 (build 216) — 2026-10-11

**Highlights:**
- **Check checks your answer.** Type or say what you remember and a model judges it: right, partly or not quite, with what was missing. Its verdict is the grade you confirm with one key, or overrule.
- **A card never asks about "this lecture".** Every card is checked before it is saved, and the cards you already have are rewritten once where they point at a lecture, paper or talk without naming it.
- **Feynman Technique in a notebook's Studio.** Pick a paper and explain it from memory; the chat asks, one question at a time, where your explanation has a gap.
- **Clicks feel instant.** The Library, its search and Settings no longer redo whole-library work on every click or keystroke.

## 0.141.0 (build 215) — 2026-10-11

**Highlights:**
- **The chat looks like Codex.** A solid composer card with your notebook on a tray behind it, a dark send button, your messages as a light pill with Copy, and replies in Codex's reading rhythm.
- **Cards ask for your answer.** Type or say what you remember, then Check, or press I Don't Know.
- **Setup asks one thing at a time.** Each page has one question and one button.
- **A chat can open a paper and point at what it explains**, and "open my notebook" really opens it.
- **A notebook made from a chat starts with that chat's sources**, and its suggestions follow them.
- **Free mode is gone**, and "What I'm working on" is kept in the background instead of as a page.

## 0.140.0 (build 214) — 2026-10-11

**Highlights:**
- **Memory cards look like cards.** Reviewing, the Memory pane, To Check and a chat's saved cards now show each card as an index card, with a deck that shows how many are left and a strip of how each card went.
- **Papers you marked paywalled stay marked.** Some papers marked paywalled long ago came back as "PDF needed" after the move to the new iCloud sync. A paywalled paper without its PDF now syncs as paywalled; one that already lost the mark needs Mark as Paywalled once.
- **Selected papers stay readable.** Selecting papers in the Library no longer hides their byline and "PDF needed" in the selection colour, and "PDF needed" sits at the end of the byline.

## 0.139.2 (build 213) — 2026-10-11

**Highlights:**
- **Dragging the Library to the edge of the window docks it.** With the Library filling the window, dragging its sidebar row to an edge now docks it there and Chat takes the rest of the window; dropped on the other edge, it moves across.

## 0.139.1 (build 212) — 2026-10-11

**Highlights:**
- **iCloud sync survives a move to another Apple team or container.** A Mac that kept the old container's sync state used to read an empty new container as "your data was removed from iCloud" and stop; it now starts fresh there. A real purge in the same container still waits for you.
- **"Upload my library to iCloud again" uploads everything.** It no longer treats a library as already seeded when only the old container had been.

## 0.139.0 (build 211) — 2026-10-11

**Highlights:**
- **The library is one pane you drag in.** The Sources panel on the right edge is gone. Click **Library** in the sidebar and it fills the window, or drag the row to an edge of the window and it docks beside your chat, a Page or a canvas, with the same tabs, search and row menus. Its sources drag into a chat or onto a canvas.
- **Google Drive asks you to sign in once.** One read-only sign-in, then a folder chooser inside ForeverLM (My Drive, Shared with me, shared drives and search). A disconnected or revoked connection shows **Reconnect Google Drive** above Drive recordings and the Meetings list, and Cancel appears wherever the app waits for Google.
- **Setup's AI step is two short pages.** **Connect OpenRouter**, then **Pick your models**, one question at a time; the data-policy note and Free mode row stay in Settings › AI Usage.
- **A paper's question markers are sharp.** The ?, ✓ and ↻ markers in a PDF's margin are drawn by the Mac at full resolution at any zoom, and clicking one opens its question as before.
- **Clicking the calendar glyph no longer quits ForeverLM.** The pill that names an icon-strip button on hover is measured once, so it can no longer resize itself until macOS ends the app.
- **7 days free, then $19 once.** The paid app's free days are 7, taken from the account server, and the pay screen says "Your free days are over". The account page on foreverlm.com is **Billing** alone: its usage totals and breakdowns are gone, since what your key spends is on OpenRouter's activity page and in Settings › AI Usage.

## 0.138.1 (build 210) — 2026-10-10

**Highlights:**
- **ForeverLM is a paid app: 7 days free, then $19 once. No subscription.** Your first sign-in starts 7 free days of the whole app, with no card. After that, the Early user deal is $19, paid once, in Settings › Billing, and it covers the Mac, iPhone, iPad and web library, unlimited notebooks and sources, and Claude, ChatGPT, Grok or Gemini over MCP. AI runs on your own OpenRouter key, at OpenRouter's cost. ForeverLM adds nothing. Free mode costs $0. An unpaid account locks after its 7 free days and nothing is deleted: your library stays in your iCloud Drive (ForeverLM folder), as plain files you own, and paying restores everything. Believer, Monthly, Yearly and Lifetime are no longer sold.
- **ForeverLM is now published under its own developer account**: the app is signed by ForeverLM and your library moves to a new iCloud store. Nothing is lost: your library stays on this Mac. Once, choose Settings › iCloud › **Upload my library to iCloud again**, sign in again, allow macOS's permissions again, and enter the keys kept in your Keychain (your own OpenRouter key, Google and Zoom) once more. Narration made before the move comes with you.
- **The Space is home**: notebooks, pages, sites, lists and chats are items in one place, with your own spaces, a Chats list, and a sidebar like ChatGPT's.
- **Pages work like ChatGPT's**: type / for blocks, footnotes, and a side chat from any page.
- **A quieter window like Codex's**, with one icon rail and the calendar as a glyph above your account.
- **Reading views and cleaner Listen**: articles and papers read cleanly, and Listen cleans every text with a model first.
- **Paper metadata arrives in seconds**, and a preprint and its journal version sit side by side.
- **Change the model behind anything you are charged for**, from Settings › AI Usage › Activity.
- **Sites stay in your library**: nothing is published to the web any more.

## 0.138.0 (build 209) — 2026-10-10

**Highlights:**
- **The Canvas does what Sapience showed (beta)**: a paper shows its PDF page and turns pages in place, any card carries a note on why it is on the canvas, arrows can be For or Against and gather into a brace, mind maps draw small nodes with a colour per branch, questions carry a ? that turns into ✓, Ask makes a Mind Map or breaks a question into questions, and the chat beside a canvas shows the cards you added as chips (Add to Chat, ⌘L).
- **Sites stay in your library**: nothing is published to the web any more.
- **Selecting text no longer brings up Apple's badge and underlines.**
- **The Space has a Chats list**, and the Notebooks list a New Notebook button.
- **Change the model behind anything you are charged for**, from Settings › AI Usage › Activity.

## 0.137.0 (build 208) — 2026-10-10

**Highlights:**
- **Narration made before the move comes with you**: once your library has arrived, the narrations in ForeverLM's old iCloud Drive folder are copied to this Mac and sent to iCloud in the background.
- **Signing in clears the home's "Sign in with Apple to use ForeverLM AI." notice** as soon as the sign-in lands.
- **Notebooks are back in the Space's sidebar**, above Courses.

## 0.136.0 (build 207) — 2026-10-10

**Highlights:**
- **ForeverLM is now published under its own developer account**: the app is signed by ForeverLM and your library moves to a new iCloud store. Nothing is lost: your library stays on this Mac. Once, choose Settings › iCloud › **Upload my library to iCloud again**, sign in again, allow macOS's permissions again, and enter the keys kept in your Keychain (your own OpenRouter key, Google and Zoom) once more.

## 0.135.0 (build 206) — 2026-10-09

**Highlights:**
- **The Canvas works like Heptabase's whiteboard**: write an Idea right on its card; give cards a size, a fold and a colour; draw curved, straight or elbowed arrows with heads, dashes and colours; make a region a mind map; turn on Focus mode or the minimap; use Heptabase's keys; right-click anything for its menu; open any card beside the Canvas, or ⌘-click it into a popup.
- **Bring anything onto a canvas**: drop Finder files, pictures and links, paste, or drag a chat or an answer onto it; Add to Canvas ▸ is on every source, Page, Idea and chat, and a card says which canvases hold it.
- **Canvases export, keep versions and publish**: Export as Image, Copy as Markdown, named versions you can go back to, and Publish… as a page on the web.
- **The Home page is gone; the Space is home**: every notebook and course is in the Space's All list, archived notebooks are in Trash, and Group by Collection groups them.
- **Day is the calendar glyph above your account**: click it for today's schedule.

## 0.134.1 (build 205) — 2026-10-09

**Highlights:**
- **Beta updates reach your Mac sooner**: the update is offered the moment a build is uploaded; the smaller delta downloads are added to the feed a few minutes later.

## 0.134.0 (build 204) — 2026-10-09

**Highlights:**
- **A paper on the Canvas can show only its figures**: Lay Out ▾ on a selected paper offers Pages, Figures Only and Figures + Extended Data — one card per figure, cut from its page by the paper's printed captions and named by its label; the region's inspector switches a laid-out paper between Pages, Figures and Figures + Extended in place. Assistants get the same through build_canvas (pdf_pages show).

## 0.133.0 (build 203) — 2026-10-09

**Highlights:**
- **Regions inside regions on the Canvas**: draw a region inside another and it is inside it — moving the outer one carries everything in it, and zoomed out every region folds into a face of your own Ideas, with the regions inside it as tiles until they are too small to read. The canvas's name is followed by the path of regions you are in (Canvas › Mootha › mtDNA mutations); press a step to zoom out to it, ⌘↑ climbs out, ⌘↓ dives in.
- **A paper's pages are cards on the Canvas**: select a paper with a PDF and press Lay Out Pages for one card per page, left to right in a region named for the paper; the triangle before any region's name folds it up to its name and count.
- **Your calendar on the Day clock**: the Activity pane is now Day (a Day row in the Space sidebar), with the Mac Calendar's events as a lane beside the log on the same hours; a click opens the event in Calendar.

## 0.132.0 (build 202) — 2026-10-09

**Highlights:**
- **Smaller updates**: an update downloads only what changed since your build, and the voice-picker samples are no longer part of the app (they load the first time you tap a voice).
- **Assistants can use the Canvas tools on any Mac**: the Canvas and Atlas tools are no longer limited to beta sign-ups, so an assistant connected to ForeverLM can lay a paper out on a canvas.

## 0.131.0 (build 201) — 2026-10-09

**Highlights:**
- **Paper metadata arrives in seconds**: a paper's title, authors and venue are read from its PDF's first pages straight away instead of waiting on publisher and registry lookups.
- **A preprint and its journal version sit side by side**: adding the published paper no longer says the preprint is already in your list; the preprint stays with its notes and chats as an earlier version.

## 0.130.0 (build 200) — 2026-10-09

**Highlights:**
- **Canvases in a notebook** (beta features on): a notebook's Studio has a Canvas tile and lists its canvases, its canvas's tray opens on its sources, and a source or Doc set down in its frame joins the notebook.
- **Passages on the Canvas**: a highlight in a paper shows as its quoted words, and a double-click opens the paper at them. Drag a highlight from the Reader's notes onto a canvas, or choose Add to Canvas.
- **Assistants can lay a canvas out**: one call writes note cards and quoted passages, groups them in labelled regions and draws arrows between them.
- **Notifications center**: the × on a corner card hides it under a bell above your avatar, where each card's own × answers it.

## 0.129.0 (build 199) — 2026-10-08

**Highlights:**
- **Reading views**: in the Reader's ⋯ menu, Reading View… takes your own words, such as "remove the inline citations", and hides what a model names on the page. The article is unchanged, and Show Original brings it all back. Chats can do it too, through four new tools.
- **Listen cleans every text with a model**: citations and the reference list are left out of the narration, for papers, articles, books and courses alike.
- **Listen starts sooner and finishes more often**: audio plays as the first parts land, cloud voices make 40 parts at a time, and a stuck narration can be finished by making only the missing parts.
- **Background work has one indicator** above your avatar, with its stage, progress and Stop.

## 0.128.0 (build 198) — 2026-10-08

**Highlights:**
- **Canvases in the Space** (beta features on): make as many canvases as you like; each is listed under Canvases and in All beside your pages, opens beside the Space sidebar, and files into a space, pins and goes to Trash like a page.
- **Lists of goals and ideas**: New ▾ › Goals List or Ideas List, or the Create in Space strip, makes a list in the space you are in; open it to set goals or jot ideas straight into it.
- **The Space on the iPhone and iPad**: Home › Spaces lists your pages as the Mac does, and a page opens in the Mac's own editor to read and edit.

## 0.127.0 (build 197) — 2026-10-07

**Highlights:**
- **The window looks like Codex's**: the icon strip and the whole title bar are one light grey band, and everything else sits on one card beneath it with a single rounded corner.
- **Footnotes in Pages**: `/` Footnote or ⌥⌘F adds a numbered note at the foot of the page; rest on a number to read it, click to go there.

## 0.126.0 (build 196) — 2026-10-07

**Highlights:**
- **Pages more like ChatGPT's**: a handle beside each block to drag it or open its options, @ mentions, subpages, Pin with a Pinned section in the Space, and a tool pill at the top of an open page.
- **Chat from a page is a side chat**: a small card over the page that keeps the page and its sources in context, and × puts it away.
- **Source search no longer stalls**: the Add sources picker narrows as you type, and it never offers a hidden source.

## 0.125.0 (build 195) — 2026-10-07

**Highlights:**
- **One icon rail everywhere, with Home for your notebooks**: the narrow rail (Home, Spaces, Memory, Library, the Canvas) is the same in every window, and Home's own sidebar lists your notebooks and chats.
- **Each background task can have its own model again**: Settings › Background has Text-only, Multimodal and Tasks tabs, and a meeting that must stay off a free model now waits instead of running on a model you never chose.
- **Settings › AI Usage is quieter**: one line per row, Activity opens on Today, and an item opens its source, notebook or chat.
- **Opening a meeting recording no longer transcribes it**: Get transcript is a click, so nothing is billed by looking.

## 0.124.1 (build 194) — 2026-10-07

**Highlights:**
- **Chat fixes**: a retried reply is timed from the retry and shows only the pages it wrote, and a chat continued on the web or the iPhone no longer feeds the model the page and card lines a Mac reply stores.
- **Spaces stay in step**: a space deleted on another device leaves this Mac's sidebar at once, and a duplicated page stays in its space.
- **A stuck assistant call can be hidden**: 15 seconds after Stop, its row in the work chip shows ×.

## 0.124.0 (build 193) — 2026-10-07

**Highlights:**
- **Quieter, like ChatGPT**: the rail has no counts, Sources and the Library are grey, and notebooks, Memory, Goals, the Reader, Activity and Settings show fewer buttons and say less.
- **Chat like ChatGPT's**: a reply's thinking and tool steps fold into one "Worked for …" line with Copy, Side question and ⋯ beneath, a page it wrote is a card with Open, and the composer is one box with "+" on the left and one model chip.
- **Spaces of your own**: make spaces in the Space and file pages with Move to Space, and a page keeps its earlier versions under Version History….
- **Background work is one chip** at the bottom of the window.
- **The iPhone and iPad draw less too**: one chat composer, and Home, Sources, Studio, Memory and Settings without the extra buttons.

## 0.123.0 (build 192) — 2026-10-06

**Highlights:**
- **A beta says so**: while your Mac runs a beta, **ForeverLM → About ForeverLM** reads "Version 0.123.0 Beta (192)", and the version under Settings says Beta too. The word goes once that build becomes a regular release.

## 0.122.0 (build 191) — 2026-10-06

**Highlights:**
- **Think first**: ForeverLM can ask for your own take before it shows what it wrote, on a source's Levels, a report, Find directions and a notebook chat's questions, and keeps what you said.
- **Go deeper**: in a review chat, once a topic has come back whole, Go deeper asks a question past recall; in card review, Go Deeper (D) answers a card Remembered and asks one question past it.
- **Cards a chat makes show in the chat**: a small deck in the reply, with Check Cards and Keep All.
- **A change from another device stays**: saving an older copy of a source no longer undoes a title or an author fixed on your other Mac or iPhone.

## 0.121.0 (build 190) — 2026-10-06

**Highlights:**
- **Pages are ChatGPT's Space**: Docs are Pages now, and their tab is one sidebar for New page, All, Pages, Sites, Images, Ideas, Google Drive, Recents and Trash, beside lists you can search, sort and show as a grid.
- **Type / in a page**: write with the AI, add a page inside this one, a picture, a file, a visualization, assistant instructions or a prompt, or any basic block.
- **Quieter top bars**: a page shows its menu and Share, a paper in the Reader its title, ⋯ and ×, a chat its title, ⋯ and ×; everything else moved into the ⋯.
- **The window is an inset card**: the content sits on a slightly deeper window color with rounded corners, as in Codex.
- **To Check reads as cards**: each card to check is drawn as the card it will be, with its actions under it and Keep in a bar at the bottom.
- **Chat can open things**: ask the chat to open a notebook, a page, a source or a quiz, and it shows it in the window.
- **Changes from your other devices show at once**: a title or an author changed on your iPhone or another Mac shows on this Mac without a relaunch.
- **Cheapest models first**: All models on OpenRouter sorts every maker's models by price.

## 0.120.0 (build 189) — 2026-10-06

**Highlights:**
- **Get beta releases**: Settings › General › Updates › Get beta releases brings new builds to your Macs before everyone else, through the usual update notification. The Canvas and the Atlas are beta features now, so they show only with it on.
- **Notes as a graph**: every Doc lists its Linked and Unlinked References, `((` drops in a block reference, `[[` links pages, Ideas and dates, and Daily Notes keeps a page for each day.
- **Docs and Goals on the home**: the Artifacts tab is gone. Docs (with Sites and Ideas) and Goals have tabs of their own, and pictures, audio overviews, films, walkthroughs and narrations live in their notebook's Studio.
- **The notebook List names each notebook's sources**: the first one and "+30 more", and a click lists them all.
- **Notebook icons are the drawing alone**, bigger and with no square behind them.
- **New prices**: Monthly is $4, and early adopters can take Believer at $19 a year, a price that never goes up, starting with a free week that needs no card.
- **Whole text**: podcast transcripts and articles that older builds cut at 50,000 characters are whole again, invisible hyphens no longer split words, and archived or deleted sources no longer turn up in search.

## 0.119.0 (build 188) — 2026-10-06

**Highlights:**
- **Five new ways to make sense of a field**, built to try side by side: keep the ones that help and the next release drops the rest.
- **Ask the Canvas**: select cards or a region, and under ✦ Ask in the inspector choose Bridge, Connect or Gaps for the papers that bridge them, the arrows between them, or the questions they leave open. Keep the dotted proposals you want.
- **The Atlas**: View › Atlas (⌥⌘A) lays a topic out as concepts from your library, each readable at four depths, from a few words to step by step, with the terms a newcomer needs.
- **Memory on the Canvas**: the brain switch shows which cards and regions you are forgetting; Review Here asks their cards in place, and Make Cards drafts cards from your Ideas and arrows.
- **Levels in the Reader**: the Levels button opens a paper's gist, a line per section and per paragraph beside it, and its key terms one press from a card.
- **Canvas cards say what they are about**: a placed paper reads as a few words far out, its finding closer in, and more up close.

## 0.118.0 (build 187) — 2026-10-05

**Highlights:**
- **A smoother Canvas**: cards slide to where they go instead of jumping, a pinch zooms, ⌘Z undoes, and resting the pointer on a card shows it in full.
- **Notebooks on the Canvas**: a notebook you set down stays linked to it, takes in the sources you add later, and zoomed out reads as its takeaways.
- **Calmer clicking on the Canvas**: pressing no longer shuffles the cards, a drag across empty canvas selects, and a card lands in the slot you let it go over.
- **Docs fold like an outliner**: fold a bullet's sub-bullets or a heading's section, and a doc reopens folded as you left it.

## 0.117.1 (build 186) — 2026-10-05

**Highlights:**
- **Your library's upload to the new iCloud store resumes and finishes**: a size check stopped it at its first step on every round.

## 0.117.0 (build 185) — 2026-10-05

**Highlights:**
- **A series folds into one card on the Canvas**: a book's chapters, a show's episodes or a course's lectures become one stacked card with its cover; double-click to fan it out.
- **The Canvas shows pictures**: covers, a PDF's first page and artwork, as the Library's rows do.
- **The Canvas reads at every zoom**: a region's name and summary sit above its frame, and no card shows a title cut to three letters.

## 0.116.0 (build 184) — 2026-10-05

**Highlights:**
- **The move to the new iCloud store finishes**: a Mac that had to postpone its catch-up of the old store now runs it, then uploads your library.
- **The Map is now the Canvas**, and it holds what you think rather than every source you own.
- **The Canvas goes on across a second display** with Extend to Other Display.

## 0.115.0 (build 183) — 2026-10-05

**Highlights:**
- **Your library moves to ForeverLM's new iCloud store** on first launch: per-record sync, teams as shared spaces, and an iPhone and web that read your whole library. Settings › iCloud shows the move until it is complete.
- **The Map**: your whole library on one zoomable plane, arranged by you.
- **Notebooks**: Add to Sources files into the window's notebook, citations from outside the notebook are marked with Add to Notebook, a notebook keeps its suggested questions, and Studio lists Make Cards runs and pictures.
- **Cards on the iPhone**: To Check with Keep, Edit and Skip, and cards that agree between Mac and iPhone.
- **Courses** on the iPhone, iPad and web home, and a **Not in any notebook** filter in the Library.

## 0.114.0 (build 181) — 2026-10-05

**Highlights:**
- **A mnemonic reading is drawn on the paper's PDF**: a marker in the margin beside each passage a question tests, and a card that opens at the marker.
- **The Reader stands left of the chat** in a notebook, with the swap arrows back on the divider.
- **Every display, layout and remembered choice is settable over MCP**, so your assistant can set what you can.
- **A book counts once** in a notebook's source count, and **a long notebook title wraps** in full.
- **Fixes**: the notebook window's icon strip no longer cuts across the traffic lights, and a highlight's colour edit keeps its long note.

## 0.113.0 (build 180) — 2026-10-04

**Highlights:**
- **A notebook is a notebook everywhere**: the app, the storage and the MCP tools say notebook, and links to a notebook say notebook too.
- **Courses are their own thing**: a course belongs to no notebook, and shows as a card on the Notebooks home.
- **A banner the morning after**: finish something and the next day asks whether to make it into cards.
- **Mnemonic readings**: read a book with questions in it, on the Mac, the iPhone, the iPad and the web.
- **A shorter rail and a list view of your notebooks**, on the Mac, the iPhone and the iPad.
- **A new notebook needs no name**: the title is made once you add sources.
- **Video overviews**: a notebook holds them, and you can import one from Gemini Notebook.
- **A read-aloud model is tested before it is used.**
- **Groundwork for the next iCloud store**, built and not switched on yet.

## 0.112.0 (build 179) — 2026-10-03

**Highlights:**
- **Share a notebook in one step**: Share at a notebook's top right invites people or copies a link, and its sources go with it. The first time, ForeverLM asks you to confirm you have the rights to share them.
- **Collections**: group notebooks into collections, with a Collections tab on the Notebooks home, on the Mac, the iPhone and the web.
- **Notebooks in colour**: each notebook is a soft-coloured card with its emoji, and each Studio tile wears its own colour.
- **A notebook's chats read what you tick in**: its own ticked sources, and a linked notebook's only once you tick it; the Studio uses only the notebook's own sources.
- **All chats**: every chat in a notebook, searchable by title.
- **A quick assistant over any app**: ⌃⌥Space brings up a listening bar that hands what you say to a new chat.
- **Podcasts you confirm**: a found episode waits for your Confirm, and a confirmed one fetches its transcript under its show's name and picture.
- **Your library is copied before it updates**: a copy beside it that takes no extra disk space at first, as groundwork for ForeverLM's next iCloud store.

## 0.111.1 (build 178) — 2026-10-02

**Highlights:**
- **Apple Podcasts episodes import natively**: a pasted episode link, or one added by an assistant, goes directly to the named episode and fetches its transcript after confirmation.
- **Podcast confirmation works through assistants**: `resolve_podcast_match` now confirms the exact match offered by `find_podcast_match`, instead of losing it between calls.

## 0.111.0 (build 177) — 2026-10-02

**Highlights:**
- **A notebook in three panels**: Sources, the chat with the full Reader beside it, and Studio, as in Gemini Notebook. Studio stays on screen while you read: opening a paper folds Sources to a strip of its sources.
- **One search for your sources**: the Sources column searches the notebook and your whole library as you type, and the web or PubMed when you press Return; results arrive as a card that widens into the whole list.
- **The rail steps back in a notebook**: a narrow strip of icons, with the notebook's chats in a menu, in the chat's header and under an empty chat.
- **Studio says what it made**: "Briefing · 6 sources · 1h ago", a dot until you open it, Rename, and Prompt and Sources.
- **Notebook Settings**: a notebook's instructions, description, Goals, Tasks and Files, from its name.
- **Your cards on the iPhone**: today's cards one at a time, across every notebook or one, a notebook's Practice, and your library from a notebook's Sources.
- **The web notebook too**: the same search, settings in a dialog, the full Reader beside the chat, and tabs on a narrow page.

## 0.110.0 (build 176) — 2026-10-02

**Highlights:**
- **Notebooks at the center**: every window opens in the notebook you were working in, and the Notebooks home (⌘P) and your whole library, full window (⇧⌘L), are one click away.
- **A notebook's Studio makes things**: an audio overview, cards, a report, a course or an explainer from its ticked sources, and everything it makes stays in the notebook and opens beside the chat.
- **Reports from your sources**: a briefing, a study guide, questions for a meeting, feedback on a document, or your own, each claim citing its source.
- **The rail leads with your notebooks**: New chat, Memory, Browser and Library at the top, then your notebooks with their chats; the home's Artifacts tab shows what is not in a notebook yet, with Add to Notebook.
- **Memory is your cards**: drafted for you as you finish sources or with Make Cards, checked in To Check, reviewed one at a time and sometimes worded differently, across every notebook or one; Practice goes through one notebook's.
- **Voice on iPhone and CarPlay talks turn by turn** with your chat model; dictation writes your words after you stop.
- **The iPhone opens on your notebooks**, each with Sources, Chat and Studio.
- **On the web**: a notebook writes reports, asks your Mac for audio overviews, cards and courses, and dictates again.

## 0.109.0 (build 175) — 2026-10-01

**Highlights:**
- **A notebook fills the window**: open one and its sources sit on the left with a tick for what its chats read, the chat and what you are reading in the middle, and your library on the right to add from in one click. Each window keeps its own notebook.
- **Add sources from anywhere**: search your whole library, paste a link, drop a PDF, or let Discover find what the notebook is missing on the web.
- **Audio overviews**: a notebook makes a spoken overview of its sources, priced before it starts, that plays on your Mac, iPhone and CarPlay.
- **Chat answers are easier to read**: they lead with the point, suggest three questions to ask next, and Save to note keeps an answer as a Doc.
- **Memory by card**: a card you have not answered yet waits until the day after you kept it, and an early right answer no longer pushes it further out.
- **Ideas from the whole text**: a long chapter or transcript now yields ideas from its end as well as its opening.
- **Slides from your other Mac**: slides captured on one Mac show on the other.
- **Suggested models stay current**: each Suggested list moves to a lab's newest release on its own.

## 0.108.0 (build 174) — 2026-09-30

**Highlights:**
- **Bring a Gemini Notebook in as a Project**: paste a notebook's link and its sources, chats and notes come into your library, the chats kept as chats and the notes as Docs. An assistant can do the same over MCP.
- **Your day is your Mac's Calendar**: the Planner is gone, the chip at the bottom left shows today's calendar, and a chat plans your day by adding events to it once you agree. The chip's popover lists today's events, joins a Teams, Zoom or Meet call and starts a bout; "Plan your day?" asks on mornings your calendar holds nothing you planned; and ForeverLM never changes an event other people are on. Google Calendar accounts now come through the Mac's Calendar (add them in System Settings › Internet Accounts), and a Teams or Outlook work calendar reaches it the same way, as a Microsoft Exchange account, or as a subscribed published calendar. Learning bouts and the Activity log stay, and tomorrow's memory review is still prepared in the evening; it no longer waits for *Shutdown complete*.
- **Find on YouTube finds a podcast episode whatever its upload is called**: it reads the videos the episode's own page links and the show's channel before it searches, and an assistant can do the same over MCP.
- **Add an Exchange account from ForeverLM**: Settings › Plugins › Calendar opens Internet Accounts to sign in with Microsoft Exchange, and a calendar added after you chose yours shows until you untick it.
- **Walkthroughs read like a textbook**: every card explains in plain words, step by step, a question you miss in a walk comes back in your memory review, a card shows the work it cites, and drawn pictures reach your other Macs and your phone.
- **Sources listed by name, once**: a chat reply that lists sources shows each one's thumbnail, title and byline in a single list, not a row of numbers over a second list.
- **The Reader scrolls again, and long transcripts stay smooth**: an article scrolls and takes clicks, and an hour-long transcript open in another pane no longer freezes the app.
- **A call right after the standup joins it**: a reconnect in your personal meeting room files into the standup's session, even when the standup's recording was stopped early.

## 0.107.0 (build 173) — 2026-09-29

**Highlights:**
- **Side chat in the Reader**: select words in any reader and ask about them in a popover beside the passage, without starting a chat.
- **Rewrite a Doc section by section in one chat**: the next passage you highlight joins the chat already working on that Doc.
- **An assistant's edit lands while you type**: a chat, Claude or Codex editing a Doc no longer fails because you changed another part of it.
- **Figures keep their top**: a figure's crop no longer loses its panel letters, legend or header band under a short running head.

## 0.106.0 (build 172) — 2026-09-29

**Highlights:**
- **Goals and Ideas live under Artifacts**: each is a tab of the Artifacts home, and any two kinds of artifact, Docs and Ideas say, open side by side.
- **Docs rewrite on a model you choose**: the ForeverLM mark in Edit with AI picks it, and a picture an assistant puts in a Doc now shows there.
- **A pinch zooms where the pointer is**, in every reader, so the words under your fingers stay put.
- **A day has one plan**: the Planner's numbered columns are gone, and a redraw changes only what is still ahead.

## 0.105.0 (build 171) — 2026-09-29

**Highlights:**
- **Walk through a YouTube video**: each step of a talk's walkthrough holds the video at its moment while you read, and play hears it from there.
- **Connecting an assistant works on a new Mac again**: setting up the MCP address uses your own Apple sign-in.
- **The Sources tab bar shows its ⋯ only when some source types have no room.**

## 0.104.0 (build 170) — 2026-09-29

**Highlights:**
- **Ask about the moment of a video**: typing a question in the chat beside a YouTube video pauses it, and the answer is about what is on screen and what was just said.
- **Your question shows the moment it was asked at**, with the frame the answer read; a click plays the video from there.
- **A slide search finds the slide its words were said over**, even when they were not said together.

## 0.103.0 (build 169) — 2026-09-28

**Highlights:**
- **An EPUB book scrolls as one book**: past a chapter's end the next one follows, on the Mac, iPhone and iPad, and the Reader's title and position follow the chapter you are in.
- **Contents lists every chapter of an EPUB book and jumps to it**; on the Mac, Find searches the whole book, and its contents page and endnote links scroll to what they name.
- **Highlights on iPhone and iPad land on the words you marked**, in articles as well as books.

## 0.102.0 (build 168) — 2026-09-28

**Highlights:**
- **No YouTube rabbit hole**: a YouTube video plays alone everywhere in ForeverLM, on the Mac and in Web Studio, and YouTube's feed, channels, search and recommendations never open.
- **Checkpoint quizzes fall where a topic ends**, and a quiz answer's slide says which moment of which lecture it comes from, once.
- **A chat keeps its reasoning effort**: a reopened chat takes back its effort and speed, and a new chat starts on the effort you last picked.
- **Settings › Billing is just your plan**, with cancelling in one place; your key, Free mode, spending and activity are the new AI Usage pane.
- **Every model pane lists models the way Chat does**, with a search over all of OpenRouter; each Chat model has a Choose provider button, and each provider shows its country's flag.
- **A paper import turns away a PDF that is some other paper**, over MCP, in the Studio and from the AI browser.
- **The Planner opens from the Now chip**, which shows the day's schedule first, and Settings shows how much iCloud ForeverLM uses.

## 0.101.0 (build 167) — 2026-09-28

**Highlights:**
- **A quiz's pictures are placed by ForeverLM**: each question's picture and its answer's picture show where they belong, and a chat never shows a picture this Mac does not hold.
- **Older video transcripts are held to their captions too**: what the formatter left out goes back, and what it repeated or made up comes out, in every library.
- **Every chip on an Idea or Goal row reads as itself** to VoiceOver.

## 0.100.0 (build 166) — 2026-09-28

**Highlights:**
- **Find directions toward a goal**: ForeverLM searches the literature and the web from a Goal, a Project or an Idea and proposes a handful of directions, each with its papers, the case against it and the cheapest test. Pursue one or set it aside, and the next search learns from your answers.
- **Free literature search in every chat**: PubMed in about a second, with abstracts, DOIs and free full text, even on free models.
- **Setup recommends a set of models**: chat on an open-weights model run only by hosts in the US, and background work on free models with a cheap backup.
- **Settings › Chat is a list**: one suggested model per maker with its logo, price and speed, then every OpenRouter model by maker.
- **A quiz's Rewatch opens where the lecture says the answer**, and a formatted video transcript keeps what the video says, with every caption time on its words.
- **A quiz waits for your answer to be graded** before it moves on, and a chat shows only pictures that exist.

## 0.99.1 (build 165) — 2026-09-28

**Highlights:**
- **A figure is cropped to its own drawing**: walkthrough cards, quiz pictures and connected assistants show a paper's figure without the legend above it, the column of text beside it or the other figures on its page.
- **A figure sits on the page that shows it** when its legend is printed under another figure, overleaf, or behind a watermark on every page.
- **A quiz's lecture slide is shown fully built**, as it stood before the next slide came up.
- **Zoom meetings read the same way**: every session in a meeting folder is titled by its day and names who was there, and a recording nobody spoke in is not filed as a meeting.

## 0.99.0 (build 164) — 2026-09-28

**Highlights:**
- **A figure is shown from its own page**: walkthrough cards, quiz pictures and connected assistants show a paper's figure even when its legend is printed on another page, or pages away, instead of the text around the legend.
- **The side chat reads the paper**: ask about words in a reply and the answer comes from the chat's sources, in a popover that stays open until you close it.
- **Overnight tasks try hard before they fail**: a scheduled task falls back to the Chat model's backups, tries again later on the same receipt, and can keep the Mac awake while it is plugged in.
- **A slow free model offers a paid one**: after 20 seconds with no answer, a line under Thinking offers a paid model, or Don't ask again.
- **Billing names the model behind every row** of AI activity, and shows how many free-model requests your OpenRouter key has left today.
- **"Plan your day?" waits in the sidebar's footer**, and the Reader's title has a grip that drags the source into the chat beside it.

## 0.98.0 (build 163) — 2026-09-27

**Highlights:**
- **Every OpenRouter image and video model, in Settings**: Settings → Images and → Videos list every model OpenRouter serves (46 image and 25 video models today, new ones appear on their own), grouped by maker with OpenRouter's price on each card.
- **Every speech and transcription model, too**: Read Aloud and dictation offer every OpenRouter speech and transcription model, each priced in the unit OpenRouter bills it by.
- **Everything goes through OpenRouter**: pictures, explainer clips, voices and transcription all run on your OpenRouter key, or through ForeverLM on a comped account or a balance bought before.
- **A chat keeps every answer with its own reply**, even after a turn was cut short, and a quiz's Skip is a small icon beside copy; the thumbs are gone.
- **An assistant's work popup can be tucked away** into a small chip and brought back, and adding pictures to quizzes shows how far it has got.

## 0.97.0 (build 162) — 2026-09-27

**Highlights:**
- **Courses on the iPhone**: each course opens its page, with the Mac's checks, locks and quizzes, and a quiz finished on either device opens what follows on both.
- **Quiz questions can be skipped**, a finished quiz's missed questions can be answered again to raise the score, and a finished quiz opens the rest of the course whatever its score.
- **A course's lectures are named for what they teach**, after a playlist import or from the course's menu, and quizzes ask only about the content, never the course's logistics.
- **A course can be shared with a team**, and each teammate takes it on their own.
- **A quiz question can show any picture**: a lecture's slide, a reading's figure, or one drawn for it, and a quiz aims for a picture on every question it helps.
- **A quiz taken in Claude or ChatGPT is saved answer by answer**, so one stopped halfway keeps what was answered.
- **An assistant's paid jobs show in the window with a Stop button**, and `cancel_ai_work` stops them from the chat; a long job no longer holds up the assistant's other calls.

## 0.96.0 (build 161) — 2026-09-27

**Highlights:**
- **A watched video can be marked not watched** from its row's menu, the Reader and its course page, and the mark holds on every Mac.
- **A paper's title keeps the Greek letter its PDF lost**: a DOI's registered title restores it, for new imports and for papers already stored.
- **An article's author is a name, never a piece of its page's head**, and the stored authors that were not names are cleared.
- **A lecture's cited textbook is matched on the shelf**, a slide that prints only a DOI is kept as a citation, and the web lookup has room to answer.

## 0.95.0 (build 160) — 2026-09-27

**Highlights:**
- **Courses have a home of their own in the sidebar**, laid out like Khan Academy: a page per course with a card per lecture, its video, readings, notes and quiz, and **Continue** at the top.
- **A quiz you haven't passed holds back the lectures after it**: three in four right opens them, a pass is kept through retakes, and a video that would play on into a locked lecture offers the quiz instead.
- **Everything done in a course carries the same green check**, finished rows are drawn lighter, and the next thing to do is tinted.
- **Quiz answers are graded on the chat's own model**: a basically right answer counts as right, and a half answer gets one short follow-up before a grade.
- **The side chat over selected words is big enough to read in**, and grows as its answer streams.
- **A Background model can list up to ten backups**, a lab's models sort newest first, and Setup asks whether meetings stay on a paid model.
- **Settings says when macOS has ForeverLM's notifications turned off**, with a button to the switch.
- **Catalog titles read H₂O₂ and K⁺**, not their HTML tags, everywhere.
- **A morning with no plan asks "Plan your day?"** from the window's corner.

## 0.94.0 (build 159) — 2026-09-27

**Highlights:**
- **Quizzes ask about a lecture's readings too**: the textbook pages planned for a lecture, and any reading filed under it, get questions of their own after the video's, each naming its page, and a miss links back to that page.
- **Every point of a lecture gets a question**: the writer first lists every key point and fact of the video, and any point it leaves without a question is asked for again before the quiz is saved.
- **Quiz questions can show the slide they are about**, above the question or with the answer, and a finished quiz reopens on its results instead of starting over.
- **A chat about a lecture knows the course's quizzes** and links the one written for it, instead of making up questions of its own.
- **Finding a lecture's papers no longer imports them**: you see what the lecture cites first, then add the ones you want; a slide in the chat lists the papers read off it, to open or add.
- **A cited paper with no matching record can be looked up again** with **Find**, which now also resolves credits that print no title, like "Szeto et al., Br J Pharmacol, 2014".

## 0.93.0 (build 158) — 2026-09-27

**Highlights:**
- **OpenRouter's Free Models Router is back, and Free mode recommends it**: it sends each request to a free model that is up, so it fails less often than any single free model, and it can never land on a paid one.
- **A model whose test run failed stays in the pickers**: choosing it runs the test again, and a newly picked model shows in the composer at once, with no "Testing …" line.
- **Monthly and Yearly start with a 30-day free trial**, up from a week, and nothing is charged if you cancel before day 31.
- **Setup explains OpenRouter**: make an account, add $10 of credits, ForeverLM adds nothing to token prices, and the models' terms are yours, with a link to OpenRouter's privacy settings.
- **Background models have their own Settings pane**, which recommends free models for background work except meetings, whose transcripts may be private.
- **Deep Research runs on the chat's model**, not the Background model, and a free model that starts costing money now always moves to another free one.

## 0.92.0 (build 157) — 2026-09-27

**Highlights:**
- **A Teachable course imports with its transcripts**: sign in to the school in ForeverLM's browser and paste a lecture link, or ask your assistant for the whole course. Each transcript is made from the lecture's audio.
- **A course quiz opens on question 1 at once**, straight from the stored quiz, instead of waiting for the tutor.
- **A quiz's tutor knows the lectures' planned readings**: a missed question links the reading that explains it, and the tutor can summarize the planned pages.
- **A busy grading model is retried**, and if it still fails the tutor offers to switch it.
- **Free mode needs a ForeverLM plan**: with a plan, it keeps your key to OpenRouter's free models so nothing is charged.

## 0.91.0 (build 156) — 2026-09-26

**Highlights:**
- **A course's quizzes show again after a relaunch**: they were always saved, and now the course reads them the moment the app opens.
- **Generate plans a course with you in the chat**: it proposes modules and sources, revises them with you, and builds the course when you say so. `/course` starts it from any chat.
- **A module can get an explainer video**, made after you confirm its price and filed under that module.

## 0.90.0 (build 155) — 2026-09-26

**Highlights:**
- **Monthly and Yearly start with a free week**, signed up for with a card at checkout and never charged when cancelled in time, and the pricing says that free models make ForeverLM free.
- **If you cancel, you can say why**: Cancel Plan… asks a few optional questions, and Keep My Plan takes a cancellation back.
- **Setup can start in Free mode, with no plan**: your key runs only OpenRouter's free models, and nothing is ever charged to it.
- **A course quiz is taken in the chat**, as a problem set from recall to challenge, and one left halfway is picked up where it stopped.
- **Quizzes are named by their topics**, with a symbol and a picture on request, and a course's papers sit under their lecture.
- **Background work falls back on up to two backup models** when its own model cannot answer.
- **Models are chosen right in Settings**: Chat, Images and Videos pick from cards, and a pick under test shows on the card.

## 0.89.0 (build 154) — 2026-09-26

**Highlights:**
- **A course is one path of things to do**: lectures, readings, problem sets and quizzes alternate directly under it, the Lectures folder is gone, and a quiz row is the size of a lecture row.
- **The daily review card asks one question at a time** and takes the answer right under it, on every day's review.
- **What's New reads as an update beside your own note**, not as a comment written over it.
- **Chat on a passage opens a new chat even right after a relaunch.**
- **Each task can choose which host runs its model**: in Settings › Chat › Choose Models…, pick Automatic, Cheapest, or one host by price, speed and precision.
- **A model you choose is tested on the spot**, and pickers hide only the models that failed a test run.

## 0.88.0 (build 153) — 2026-09-26

**Highlights:**
- **The memory review is organized by topic**: the planner groups the day's ideas across sources, each topic is one question graded against all of them, and the card shows which ideas came back.
- **Courses can be laid out Khan Academy style**: Write Quizzes puts a practice quiz after every lecture, checkpoints along the way and a course test at the end.
- **A course can read along with a textbook**, with the sections worth reading chosen for where you're coming from.
- **What's New on a passage**: highlight a claim in a book or paper and a Deep Research chat writes what has been published since onto the highlight, with the papers ready to add.
- **Setup asks which models you want**, and background work starts on a free one.
- **Keyword search finds Δψ** and every other keyword the text spells in another case or with a ligature.

## 0.87.0 (build 152) — 2026-09-25

**Highlights:**
- **A video can quiz you while you watch**: turn on Quiz me, and it pauses at the end of an idea to ask about it.
- **A course alternates lectures and quizzes**: a Quiz row after every lecture asks about it.
- **The chat shows slides again**, and can capture any moment of a video.
- **Every model choice sits under AI Models in Settings**, with Images and Videos back.

## 0.86.2 (build 151) — 2026-09-25

**Highlights:**
- **A citation card you click stays open**, so Add to Library can be clicked.
- **Google Docs go dark with the app.**
- **Asking what you watched today shows each video in the chat.**

## 0.86.1 (build 150) — 2026-09-25

**Highlights:**
- **A citation in a paper you added shows its reference card.** Hover or click a superscript in a PDF in your library, or among a Project's files, to read the reference and add the cited paper.
- **When a course plays on to the next lecture, the Reader follows it**, with that lecture's title, transcript and notes.
- **Extract papers is offered on every YouTube video**, course lectures included.

## 0.86.0 (build 149) — 2026-09-25

**Highlights:**
- **AI runs on your own OpenRouter key with a Monthly, Yearly or Lifetime plan**, billed by OpenRouter at cost.
- **A parent's plan covers the family**, and parents can assign sources for their children to learn.
- **Setup asks which model background work runs on**, and every background task can run on a free model where one can do it.
- **Highlights and notes from Zotero and PDFs come in as ForeverLM highlights.**
- **Clicking a citation in a PDF shows its reference card in place.**
- **An empty chat suggests what to read next from your recent reading.**

## 0.85.6 (build 148) — 2026-09-25

**Highlights:**
- **EPUB books open with their illustrations on your other Mac**, instead of as plain text.
- **Workspaces moved to View ▸ Workspaces.**
- **Setup shows ForeverLM answering from your library inside Codex.**

## 0.85.5 (build 147) — 2026-09-25

**Highlights:**
- **The model picker opens above the composer** instead of running off the bottom of the window.

## 0.85.4 (build 146) — 2026-09-25

**Highlights:**
- **Book chapters open their text** on a Mac the book's file never reached, instead of a blank page.
- **A Goal's details wrap whole** in a narrow pane.
- **A walkthrough opened in a new chat shows its card** instead of the welcome screen.

## 0.85.3 (build 145) — 2026-09-25

**Highlights:**
- **A freshly written explainer stays on screen** instead of falling back to "No Content".

## 0.85.2 (build 144) — 2026-09-25

**Highlights:**
- **Explain opens the explainer it just wrote**, instead of an empty Reader.

## 0.85.1 (build 143) — 2026-09-25

**Highlights:**
- **Wide equations in a chat fit the column** instead of running off its edge.
- **Clicking an animation on the Artifacts home opens it.**

## 0.85.0 (build 142) — 2026-09-24

**Highlights:**
- **Settings is eight panes**, and everything that left the window can still be changed from chat.
- **Billing is four cards**: plan, your own key, balance and limits.
- **Each course shows whether you've finished it**, with a ring that fills as you finish lectures.
- **X bookmark sync spends far less of your X API credit.**

## 0.84.0 (build 141) — 2026-09-24

**Highlights:**
- **Setup does the work in seven screens**: Full Disk Access first, then podcasts, your Reading List and your papers set up for real, and everything else under More sources.
- **Choose which podcast shows to keep, hide or leave out** before anything is imported.
- **Bring your Reading List in whole, the last 30 days, or only new saves**, and your Zotero library in one click.
- **Background clean-up retries busy models and waits out rate limits**, so imports on free models get through.
- **Free mode keeps you on OpenRouter's free models**, on the Mac and the iPhone.
- **Memory reviews are dealt as cards**, and images can be renamed.

## 0.83.0 (build 140) — 2026-09-24

**Highlights:**
- **Write your own skills.** Settings → Skills holds instructions for work you ask for often. Chat uses one when your request matches it, and `/name` calls one directly; a SKILL.md from Claude or Codex imports as it is.
- **Every walkthrough card has a picture**, and an animation gets a card of its own instead of sharing one with a figure.
- **A walkthrough card can take the whole pane**: the figure large, the point in large type, one Next.
- **Chat knows what you have open beside it**, so "the article I have open" means the one on screen, not the one attached.
- **Background AI asks before re-running your whole library**, can stop at a daily limit, and prepares Listen only when you listen.
- **Paywalled papers find their free copy** through PubMed Central and open repositories.

## 0.82.0 (build 139) — 2026-09-23

**Highlights:**
- **A crash in 0.81.0 is fixed.** Build 138 quit a few seconds after launch while it located a paper's figures; if you are on 138, take this update.
- **Hover a citation number in a PDF to see the reference.** Click the card to open the cited paper, added to your library first if it is missing.
- **Walkthroughs leave the chat.** Cards no longer post messages, progress follows you across devices, and a missed question becomes a Memory target.
- **A question asked on a passage shows that passage** in its chat bubble, in a new chat.
- **Activity gets a By source layout** and opens on the first card.

## 0.81.0 (build 138) — 2026-09-23

**Highlights:**
- **ForeverLM is free.** An optional plan ($10 a month or $129 lifetime) lets you use your own OpenRouter key and buy AI balance without the 10% margin.
- **Start free with OpenRouter's free models.** Connect OpenRouter in Setup and chat and background work use its free models.
- **Setup asks which AI subscription you already pay for.** The last step then shows that app's own instructions for using ForeverLM from it.
- **Thinking streams in full, then folds away** into a "Thought for …" row when the answer arrives.
- **Papers keep their methods.** A paper is cleaned from its whole PDF, and sections printed after the references stay; your library is re-cleaned in the background.
- **Walkthrough cards sit above the chat**, and the paper beside it stays clear.
- **The reader and the Browser follow one set of page rules**, so a PDF on a paper's page attaches from either.

## 0.80.0 (build 137) — 2026-09-23

**Highlights:**
- **A walkthrough teaches the paper's argument in chapters.** It sets out the argument first, then writes chapters that each end on a "You can now say" card.
- **Four kinds of question.** Recall, Think first, Predict (the figure stays hidden until you guess) and Find it (click the panel on the page).
- **One point a card, with Say more chips** under a point that has more to it.
- **Walkthroughs play on the iPhone** as a deck of cards to swipe through, and the phone can write one, chat on a card and grade your answers.
- **A reader link can open in a new Browser tab**, and Back returns every page to where you left it.
- **While a chat is thinking, its status line quotes the model's own reasoning.**
- **Drop a source on a Planner block** to add it to that block's reading.

## 0.79.0 (build 136) — 2026-09-22

**Highlights:**
- **A new setup.** It opens on the story of a day's information, says what ForeverLM does beside short recordings, then walks each step in order with a recommendation for every choice.
- **Connect OpenRouter by signing in.** Setup and Settings → Billing bring back a key billed to your own OpenRouter account; a pasted key is checked before it is saved.
- **Bring your library with you.** Setup imports a reference manager's papers or a read-later app's articles once, and asks which browsers' Reading Lists to import.
- **Walk Through opens its own chat**, and each card's conversation stays with that card.
- **Walkthrough cards float over the paper** when it is open in a Reader; close them to read, and Next brings them back.
- **A chat explaining a figure outlines it in the paper beside it** instead of showing a crop.
- **The model picker shows each model's speed** beside its price, with a link to its OpenRouter page.

## 0.78.0 (build 135) — 2026-09-22

**Highlights:**
- **A walkthrough plays as a deck of cards.** Each step is a card above the chat with the figure panel cut from the paper, its points one click at a time, and dots to jump between cards. Questions asked on a card stay with that card.
- **Question cards check what you remember.** Recall the answer, show it, then say Forgot or Remembered; the result is saved with the chat.
- **The chat can see what you have open**, so "summarise this" means the paper in the pane beside it.
- **Your own OpenRouter key films with six more video models**: Wan 3.0 Prime, Wan 3.0, Wan 2.7, Kling 3.0 Pro and Standard, and FLUX.3 Video.
- **Bought balance carries a flat 15% margin, and your own OpenRouter key is billed at cost.**
- **Sign in with Apple works on a Mac account whose browser is Safari.**
- **A CarPlay quiz starts with a question, not a long silence.**
- **An update installed from another account on this Mac asks for a restart**, not a second install.
- **GPT Image 1.5 and the Gemini overnight read-aloud are gone.**

## 0.77.0 (build 134) — 2026-09-22

**Highlights:**
- **A walkthrough shows one sentence a click.** Each Next adds one point, and the outline on the figure moves to the panel that sentence names. Earlier steps fold to a line each.
- **The Planner and what you actually did are two views.** The Planner draws only the plan; the new Activity view shows the day's sittings on a clock, and the two can sit side by side.
- **The Planner offers to plan an empty day.** Once a day, a day with nothing planned asks "Plan your day?", and asking a chat to plan your day opens the Planner beside it.
- **History is time you actually spent.** Settings → History lists time blocks you read, listened or watched, and no longer counts a memory review's candidates as reviewed.
- **A book's Contents lists each chapter's sections.** The chapter you are reading opens expanded, and a click on a section goes straight to its page.
- **Every Settings control can be changed from chat.** Ask the chat, or Claude or ChatGPT, to change a voice, the image style, a plugin connection or a team name.
- **You choose where your library lives.** Setup opens with a Storage step: sync through iCloud, or keep everything on this Mac. ForeverLM says when iCloud is full.
- **Sites and animations live in your library.** Nothing is on the web until you publish it.
- **Every picture a chat draws is kept under Artifacts.** A revision edits the previous picture instead of redrawing it.
- **Your own OpenRouter key pays for everything OpenRouter serves**, including voices, transcription, images and video. New accounts start at a zero balance.
- **Chats on Gemini work again**, and chat can list a show's episodes or an author's papers.
- **Team settings are their own Settings**, and a team library still lists all your own sources.
- **The model menu shows each maker's logo**, and Grok 4.7 leads the xAI models.

## 0.76.0 (build 133) — 2026-09-21

**Highlights:**
- **A citation can open a book at the page.** The text a PDF hands the chat now marks each page, so a reply that cites a passage of a book chapter or a paper can name its page on the link. The Reader opens that page even when it cannot find the exact words, and a claim about a whole page or a figure can cite the page alone.
- **A course imports in minutes, not hours.** Formatting a lecture's captions sent the model one sentence at a time — some 370 calls a lecture. It now sends five.
- **"Open Link in New Window" works on a chat citation.** The context menu on a citation or a Sources row opens the source in a window of its own, or in any other open window, and "Open Link" opens it in the Reader beside the chat.
- **A figure step repeats the sentence in which the authors cite the panel.** Every figure step of a walkthrough quotes the paper's own sentence about that panel, found in the paper's text.
- **A highlight's card hangs below the mark, not over it.** The comment card anchors to the marked words instead of the pointer, so it no longer covers what you just marked.
- **The Planner draws nothing over anything else.** A short block prints no line it has no room for, and a sitting under 22 points is a bar; deleting a sitting asks no confirmation.
- **The course-import banner can be hidden**, and the course's sidebar row keeps spinning until the import is done.
- **A passage quoted from a reply reads as the reply showed it**, not as TeX.

## 0.75.0 (build 132) — 2026-09-21

**Highlights:**
- **A walkthrough makes one point a step.** A figure step is about one panel, which the Reader outlines while the step reads it; a step that sets up or sums up talks in the chat and marks nothing; bodies are short and a walk runs ten to thirty steps. Write Walkthrough Again gives a paper the new shape.
- **The chat follows the walk.** Back, Next and the strip's jump bring that step's row to the top of the chat, the current step's kicker draws in colour, pressing a panel letter says what that panel shows, and the strip's × leaves the walk with the steps kept in the chat. The wait before a step is named instead of blank.
- **A memory review asks a chatted-about source only what you chatted about.** A source in the review only because you discussed it is graded on the ideas that conversation reached; the rest is context the tutor never asks or grades. The tutor is told how far into a source you got, and a source's contour is graded once.
- **Figure titles are whole again.** A figure's caption is read as its printed paragraph, so a walkthrough step's figure title no longer stops where the column wrapped, and a panel's caption reads across the line breaks. Papers are re-indexed on use.
- **Science and medRxiv PDFs.** Science's red PDF button now attaches the PDF. The reader no longer sends its own request for a PDF the pipeline is already fetching, and waits out a publisher's HTTP 429 instead of showing it.
- **The chat header has a ⋯** with Open in Other Window and Copy Link, so a chat open in front of you no longer has to be found in the sidebar first.

## 0.74.1 (build 131) — 2026-09-20

**Highlights:**
- **An explainer goes through the paper's figures.** The spoken explainer of a paper now reads its figures, each named as the paper names it, and tells the findings through them in the order the argument uses them, so a listener with the paper open can find the panel being described.

## 0.74.0 (build 130) — 2026-09-20

**Highlights:**
- **The Planner draws the log inside the plan.** One time column: a block is a frame, and what the app saw you do is drawn inside the block it fell in, or between blocks when it was unplanned. A block's foot counts the minutes inside it and, for a block left open, offers Done and Skip.
- **No more "Running late".** A block past its end says running long while it may still be going, and "Not closed out" once it cannot be.
- **Full-page figures are found.** A paper figure that fills its page, with the caption opening the next page, is indexed on the page it is printed on, so walkthrough steps outline the figure rather than an empty strip. Papers are re-indexed on use.

## 0.73.1 (build 129) — 2026-09-20

**Highlights:**
- **The walkthrough writer is shown what an earlier look at each figure saw.** A figure with a stored vision analysis now hands that reading to the writer beside the caption and the words printed in the figure, the same account the animation drawer receives, so a figure step and its animation describe the picture from one reading of it.

## 0.73.0 (build 128) — 2026-09-20

**Highlights:**
- **A stretch of reading ends in a review.** After half an hour or more of reading, listening or watching that you then put down, the Planner draws a short **Review:** block for exactly those sources on the next free quarter hour and asks *Review what you just read?*, with **Review now** on the notification. Once per stretch, never for what you already reviewed; off under Settings → Appearance → Planner → Review what you read.
- **The Planner's clock draws your day.** Settings → Appearance → Planner → Your day sets the first and last hour the clock draws, six to midnight unless you change it; the setting follows your account, and a block outside the hours still widens the clock to hold it. `set_planner_settings` takes `day_start_hour` and `day_end_hour`.
- **A meeting's block asks what you want to talk about.** Where a meeting is — its Zoom or Meet link, or its room — now lives in its own field, drawn as the Join button or a room line, so the notes are yours: on a meeting the field asks *What do you want to talk about?*, a fresh agenda for each occurrence.
- **A click on a Goal opens the Goal.** The Goals tab's row opens one sheet with **Chat about it** and **Quiz me on it** first, then everything the row says, editable, with Mark done, Archive and Delete in the footer.
- **A Goal's chats.** File a chat under a Goal from the sidebar's Move to Project menu or over MCP; the Goal row shows *N chats* beside *N sources*, and the Goal editor lists them.
- **The Artifacts home is a gallery of pictures.** Every card leads with a picture of the thing — a site or animation photographed at its address, a film's poster, a doc's opening lines — and the kind tiles are filter chips on one row with the search.
- **Hidden chats live behind a right-click.** The standing *Hidden (n)* row is gone; right-click the **Chats** header to show or hide them.

## 0.72.0 (build 127) — 2026-09-20

**Highlights:**
- **Tomorrow's memory review is ready before the morning.** When you mark the day *Shutdown complete*, ForeverLM closes the day for memory: it folds the day's chats into what it knows about each source and prepares tomorrow's review, so it is waiting on your Mac and your phone. Miss the shutdown and it runs at an evening hour you pick in Settings › Memory (22:00 by default), and the morning still catches anything left. **Close the day now** and `close_day` do it on demand.
- **Highlight a figure and chat about it.** Drag over a picture in an article and the same bar appears as over words: Chat puts the figure itself in front of the model, and Highlight outlines it and keeps it with your notes. Over MCP, `create_source_highlight` takes an `image_url`.
- **Ideas: jot a thought down before it has a date.** A new Ideas tab under Goals holds a sentence, a note, and links to the sources, chats and Docs it draws on; **Make this a goal** turns one into a Goal. Six `*_idea` tools match it.
- **The Planner is the clock alone.** The side panel is gone from the Mac; **Shutdown complete** sits in the header, and once the day is shut it opens **Reopen the day** and **Plan tomorrow…**.
- **Artifacts is one row.** Click Artifacts for a page of Docs, Sites, Videos and Animations tiles, each with its count, above everything recent.
- **A removed folder leaves the list at once.** The "1 hidden" footer no longer counts something you just removed while its Undo is still showing.

## 0.71.0 (build 126) — 2026-09-20

**Highlights:**
- **Change a Goal's deadline from its row.** The date on an open Goal is a button, and **Change Deadline…** is in the row's menu; both open a popover with the same choices as **Set a goal** — Sunday, in two weeks, or a day on the calendar — and **Set deadline** moves only the date. An assistant does the same with `update_learning_goal` and `end_date`.
- **Delete a sitting from the Planner's clock.** Right-click any sitting on the day's log for **Delete…**: it asks once, then takes that sitting off the log while the day's blocks and your sources stay. Over MCP, `get_day_plan`'s log now names each span with `activity_id` and the new `delete_day_activity` forgets one.
- **Articles added from the Reader are named by their headline.** Add to Sources used to file a post under its site's name or with the publisher tacked on ("… — Amplify Partners"). The page's own title, social title, site name, first heading and structured headline are now read together, and the article is named by the headline its author gave; a title you typed yourself is never replaced.
- **A publisher's PDF viewer page attaches the PDF it shows.** A link such as JCI Insight's `/pdf` page opens a web viewer rather than the file; instead of "Failed to read PDF content", ForeverLM now reads the page for the PDF it embeds and attaches that.
- **The passage a chat is about stays at its top.** A chat started from highlighted text shows those words under its title, with the source's name beneath; click the row to open the source in the Reader at that passage.

## 0.70.0 (build 125) — 2026-09-20

**Highlights:**
- **A Zoom recording only Zoom can convert is yours to decide about.** When a meeting ends before Zoom converts its recording, or Zoom was quit first, the raw files stay in Zoom's folder and ForeverLM cannot read them. ForeverLM no longer opens them in Zoom on its own, which put Zoom's unknown-source warning on your screen at every launch. Instead the Meetings tab and Settings › Sources › Zoom Transcripts list each waiting recording with **Convert in Zoom**, your own double-click made once, after which ForeverLM files and transcribes the result, and **Ignore**, for a meeting that did not happen. An assistant can do the same with `list_unconverted_zoom_recordings` and `resolve_unconverted_zoom_recording`.
- **A paper you already have opens from the library.** Clicking a web citation to a paper the library holds, under whatever address it was saved, opens the saved copy with its notes and reading position instead of a publisher's page about it. A PubMed page that turns out to be a saved paper swaps to it once it has loaded, and the Reader's **Add to Sources** button over a page you already have reads **View in Sources** and opens it.
- **"Set up a goal" always makes a Goal.** An assistant asked for a goal without a date now proposes a deadline and confirms it, rather than filing the goal as a Project's open question.

## 0.69.0 (build 124) — 2026-09-20

**Highlights:**
- **A chat saved from Claude Code is the whole chat, word for word.** An assistant working in Claude Code can hand `import_review_chat` its own session file instead of retyping the conversation: pass `transcript_file` with the session id and ForeverLM reads every message as you saw it — your questions, including one sent mid-turn, the assistant's full answers with their tables and source links, and the times each happened. Calling again after each answer brings the saved chat level with the file, and a chat that was saved as a summary is repaired the same way. Source links in the saved chat open as cards when you reopen it.
- **A generated course's schedule is a Goal.** `generate_course` with `schedule_start` no longer fails with "Project not found": the schedule is a Goal tagged to the course's open-ended Project, so the course's dated pacing and its source pool are the two records the Goal/Project split intends.

## 0.68.0 (build 123) — 2026-09-20

**Highlights:**
- **Reorder your Goals by hand.** Drag a Goal onto another row to put it there, or use **Move Up** and **Move Down** in its menu. The order you make stays whatever the deadlines do, a Goal set afterwards reads by deadline below the ones you placed, and **Sort by deadline** brings the deadline order back. An assistant can do the same with `reorder_goals`, and `list_goals` reads your order.
- **Chats about sources are saved as they happen.** An assistant connected through the plugin now keeps every conversation about a paper, chapter, article, podcast or meeting as a chat in ForeverLM from its first answer, appending each reply as it goes, so nothing is lost when a conversation stops before it ends.

## 0.67.1 (build 122) — 2026-09-20

**Highlights:**
- **The enlarged figure is as sharp as the page.** Clicking a walkthrough's outline now opens the figure rendered for your screen, so it no longer looks softer than the PDF zoomed in.

## 0.67.0 (build 121) — 2026-09-20

**Highlights:**
- **Always generate audio for explainers.** **Explainers** is a new switch beside Articles, Papers, Books and Courses under Settings &rarr; Read Aloud &rarr; Automatic audio, on the Mac and the iPhone. An explainer is saved as an article-typed source, but it has a switch of its own, so narrating every explainer never means narrating every article. With it on, an explainer's audio starts the moment its script is written — from the Reader's Explain button, the source's menu, or an assistant's `generate_explainer` — with your selected voice and no cost question. The whole card can now be read and set from an assistant with `get_automatic_audio_settings` and `set_automatic_audio_settings` (`kind: "explainer"`).
- **The Planner's side panel says less and offers more.** Goals the day has no block toward fold into one line, *5 Goals due today, none on the clock*, with **Draw blocks** opening the redraw toward them; a Goal on the clock, or due another day, keeps its row. This week folds its absences into *9 Projects got no time* once they outnumber the planned rows, and a meeting the calendar drew counts toward the Project its series belongs to. Running behind offers **Done** and **Skipped** for a block over by more than its own length instead of fifteen more minutes. `list_goals` and the rail now agree on the days a Goal has left.
- **Animations can be walked through, and a walkthrough step can show a saved animation.** **Walk Through** on an animation in the Animations pane opens the chat beside it and plays the animation's walkthrough one step a message; each step pins the animation to one of its own steps, so the drawing follows the explanation the way a paper's figures do. Any walkthrough's step can also show a saved animation at a chosen step and conditions instead of carrying its own HTML. Over MCP, `get_walkthrough`, `save_walkthrough` and `delete_walkthrough` take `animation` in place of `source_id`, a step takes `animation`, `animation_step` and `animation_conditions`, and `list_animations` reports `has_walkthrough`.
- **Click a walkthrough's outline to see the figure enlarged.** The pointer over the blue outline a step draws on the page is the zoom-in cursor, and a click opens the outlined panel or figure large, titled by the figure's printed title.
- **Opening an animation no longer moves it to the top of the list.** Clicking an animation, a Claude artifact or a Codex site in its list used to save a fresh text copy of the page as it drew — an animation's caption and clock differ every time — which dated the record and re-sorted it to the top. An open now fills only an empty text copy; one that exists stays as it was until you choose **Refresh Text Copy**. Google Docs keep following their export.

## 0.66.0 (build 120) — 2026-09-20

**Highlights:**
- **A walkthrough plays in the chat beside the Reader.** **Walk through** opens a chat on the paper (or joins the one already about it) and shows the first step as a message: the explanation, the panel it is about enlarged, and above it the figure's label and title as a chip that takes the page straight back to it, with panel letters to follow a figure panel by panel; the step's animation plays under the message. A strip under the chat's title says step *n* of *m*, with **Back**, **Next** and a jump to any step. Type between steps and the tutor answers with the paper attached; answer a question step and the reply is the grade. The chat is saved among Chats and picks the walk back up when reopened. The separate Walk Through panel and the Explain pill are gone; the tutor can also point the Reader at a figure, panel or passage while it explains.
- **Source Classification can run on a decision model.** OpenRouter's TypeSafe Jev answers the one question the task asks — paper, article or book — with a probability per option instead of writing text. A **Decision models** submenu on the task's Advanced row offers it, `get_ai_task_settings` lists it as `decision_models` and `set_ai_task_settings` takes it for that task alone; it is a trial on that one task and appears in no other picker.

## 0.65.0 (build 119) — 2026-09-19

**Highlights:**
- **"Ask in side chat" is a small chat in a popover over the words.** Select words in a tutor's reply and the third action hangs a popover off them: the passage as its heading, a field that takes focus, the answer streaming under it. Nothing is written into the chat; an arrow button hands the exchange to a new chat when it grows into one.
- **The walkthrough column can be dragged wider.** Its leading edge is a grab handle: drag it left to widen a walk from 260 up to 900 points, never so far that the source keeps less than 320. Double-click puts it back at 340; the width is remembered across papers and scales with the UI zoom.
- **Chat on a Reader selection lands in a chat about that paper.** The Chat pill over a selection joins the open chat only when that chat is empty or its sources include the paper the words came from; otherwise the open chat is left as it is and the passage opens a new chat with that paper as its only staged source.
- **The sources chip on a Goal row opens the list of its sources.** The "11 sources" label is a button: a popover lists the Goal's pool, and a click opens that source in the Reader beside the Goals tab.
- **Merge Same-Day Sessions no longer fails when both calls had been read.** Two placed standup calls each carried an activity ledger, and the merge collided on a day only the duplicate had; the ledger now moves row by row, and a placed source no longer loses its engaged minutes on re-save.
- **A tool call the Mac finished while its relay socket was down still answers**, and a Mac that is merely slow is never reported as a plugin that lacks the tool: the relay holds the answer and delivers it on reconnect, and the gateway says the Mac did not answer instead of `Tool not found`.

## 0.64.0 (build 118) — 2026-09-19

**Highlights:**
- **Plan a Goal as its readings, a review and its work.** A Planner block now says what kind of hour it is: **Work**, **Read** or **Review**. Its one button follows: a Read opens the reading, a Review starts a review with the block's sources in context, Work opens a chat. Claude, ChatGPT and Grok plan toward a Goal over MCP with `add_time_block`, `update_time_block` and `revise_day_plan` (`purpose`, `goal_id`, `source_ids`; a review with no sources takes the Goal's), and the editor lets you change a block's kind. The Web Studio planner shows the word.
- **A walkthrough for a book chapter or an article, not only a paper.** **Walk through** appears on a chapter and on an article too: a chapter walk outlines its figures and passages in its PDF, an article walk steps through quoted passages the Reader scrolls to and flashes, and a book's row offers **Write Walkthroughs for All Chapters**. Claude and Codex can write and read them over MCP with the same four tools.
- **A walkthrough step lands on its panel, fast.** Back and Next answer in well under a second instead of a second and a half. A step about one panel boxes that panel alone and shows it enlarged in the panel, with letters to follow a figure panel by panel; every panel of a main figure is addressed in order; each figure step shows the figure's printed title; pressing the figure line or the quoted passage jumps the paper straight to it.
- **Walkthrough questions are answered in your own words.** A question step asks you to answer in the composer instead of picking from a list; the answer is graded against the paper with what was right, what was missed and the reference answer.
- **One standup, one session.** A Zoom call that dropped and was restarted files as one meeting: a second recording of the same series on the same day joins the first session's transcript under a "Reconnected at" line, and **Merge Same-Day Sessions** on a series' menu, and `merge_meeting_sessions` over MCP, fold sessions already split. A meeting's transcript is rows on its first frame, its series row wears the Zoom mark alone, and a Planner block holding only meetings is headed **Transcript**.
- **The Planner shows which readings have a walkthrough**, and `get_day_plan` lists each block's readings with their walkthrough status; blocks no longer print their hours; **the Now chip stands in the sidebar's footer**; the Memory row trails only the minutes still to go, with no flame or streak.

## 0.63.0 (build 117) — 2026-09-19

**Highlights:**
- **A paper can be walked through inside the Reader.** **Walk through**, beside Explain on a paper, writes a guided walk shown in a panel beside the PDF: each step scrolls to a figure, a panel or a quoted passage and outlines it, explains it in a few paragraphs, and some steps play a small drawn animation or ask a question graded in the panel. Select words in the PDF and press **Explain** on the selection bar to have them explained in place; **Ask about this step** hands a step to Chat. Assistants can write one over MCP with `save_walkthrough`.
- **The Planner's log carries its own answers.** A sitting the plan cannot account for is marked on its own card in the lane with a dashed edge and says why; its answers (**This is the work**, **Draw it a block**, **Count toward…**, **Extend to…**, **Leave it**) sit under a ⋯ at its corner. The side panel keeps Planned and Logged as two bars and says only how many sittings are not in the plan.
- **No two Planner blocks share a minute, and a block drags to another hour again.** A block drawn, moved or redrawn over another is refused by name; a dragged block stops flush against its neighbour or jumps past it, and every place the canvas puts a block finds the free time first. Over MCP, `add_time_block`, `update_time_block` and `revise_day_plan` refuse an overlap instead of leaving it standing.

## 0.62.0 (build 116) — 2026-09-19

**Highlights:**
- **The Planner has an X to close it.** Its top-right corner now shows the close control every other workspace surface has; closing the Planner when it is the only pane reveals Chat in place.
- **A Doc has a Share button.** Beside the More menu on an open Doc, **Share** opens a popover that is the one place to say who can open it: invite people by email (they read the page; a page reads the same for everyone but its author), an **Anyone with the link** row with Can read or No access, an **Anyone at \<team\>** row per team that shares a copy into the team and admits its members to the page, each reader with a remove control, and one sentence saying who can open the Doc, with **Copy link** beside it. Web Studio's publish dialog has the same rows and the same sentence, and `list_docs` reports it as `published_access_summary`.
- **The memory review is a committed session.** The Review mode sheet says what you are agreeing to before **Start Review**: the goal's minutes (fifteen by default), the window becomes the review, the clock counts while you are in it, and leaving early ends today's session. Leaving by any door — the ✕ by the clock, which asks first, another surface, another chat, or quitting — ends the day's session: the clock goes quiet, the chat can be read back but credits nothing, and there is no second start until tomorrow. Reaching the goal completes the day as before.
- **The Planner holds a Memory review block every day.** Today and every day ahead gets one **Memory review** block, the goal's minutes long, on the first free quarter hour. It is yours to move or delete, is never drawn twice or put back, and is marked done when the day's goal is met on any device; on today its **Chat** is **Start review**.
- **The Planner's side panel reads the log against the plan instead of listing it twice.** By day it shows **Today**, Planned and Logged as two bars, the Logged bar split by how the minutes stood to the plan (in its block, open time, off its block, outside any block), then **Not in the plan**: only the sittings the clock cannot explain, each with the off-the-block answers and, when a later block of the day named that source, **Count toward** that block. Once the day is shut down, or a past day is showing, the panel looks back: **How the day went** with the alignment sentence, **What you did** by thing, Notes, Reopen and Plan tomorrow. Web Studio draws the same two states.
- **A meeting whose transcript arrived is done.** A meeting block is the one block ForeverLM completes on its own: when the session's transcript is stored, however it arrived, the calendar block that meeting occupied is marked done in the same write that links the transcript to it. The clock still completes nothing, and a meeting that left no transcript waits for you to say it happened.
- **A Zoom meeting recorded on this Mac is found whether or not Save Captions was on.** The Zoom watcher reads the recording folders under ~/Documents/Zoom as well as the caption files: a converted recording becomes a session of its series, linked to the calendar block it occupied and transcribed by ForeverLM, a meeting that ran over into a second slot files as two sessions, and a recording Zoom left unconverted is handed back to Zoom to convert. Settings → Sources counts the recordings beside the transcripts.
- **Claude and Codex can see a paper's figures.** `inspect_paper_figure` returns a figure rendered from the paper's own PDF and cropped to it, with its caption and ForeverLM's explanation, or one panel alone; `show_source_image` shows any source's pictures by label, caption words, page or slide. The picture travels in the tool result as an image, so the assistant sees the plot rather than its caption.
- **The Now chip stands in the middle of the titlebar band.** Centred in every window's titlebar, clear of the sidebar toggle and the Sources controls, saying the block's title in full where it fits, with a hairline along its foot showing how far through the block the clock is; it steps aside while the Planner itself is on screen in that window.
- **A block's editor reads as the block, not as a form.** The title is a heading that wraps, the hour is two plain clock fields with the duration beside them, Toward and Project share one column, the block's sources sit in one Reading card, and the notes take the boxed field the Set a goal sheet uses.
- **A Goal set on one Mac survives another Mac's update.** The schema 120 step promotes to Projects only rows created before the day Goals shipped, so a Goal synced in from a newer build keeps its deadline.

## 0.61.0 (build 115) — 2026-09-19

**Highlights:**
- **Two Projects can be merged, and everything in the merged one follows.** **Merge into Project…** on a Project's ⋯ menu asks which Project it folds into and what the merged Project is called. Its sources (a source in both is kept once), chats, Goals, tasks, Docs, scheduled tasks, Schedule placements, Planner blocks, open questions, research questions, notes and workspace files move to the survivor, and the merged Project is deleted. Projects in different libraries do not merge. `merge_projects` over MCP does the same and answers what it moved; before this it left the chats pointing at a deleted Project.
- **A Goal can be for a Doc, a Site or an animation, and its row opens it.** A Goal row on the Goals tab carries the artifact it is for and opens it on click; without one, the click asks what the Goal is for. The row's menu gains **Link a Doc or Site…**, **Open**, **Change the Doc or Site…** and **Unlink**, and **Set a goal** offers the same link. Over MCP: `artifact_id` on `create_learning_goal` and `update_learning_goal`, and `artifact` on every Goal row.
- **A Goal can be deleted.** **Delete…** in a Goal row's menu, below Mark done and Archive, asks once and removes the Goal, its source pool and its Schedule tags; the sources stay in your library and a chat started from it stays in Chats. Over MCP: `delete_learning_goal`.
- **A source can be taken out of today's memory review.** Each chip above a review not yet graded carries a small × and **Remove from today's review** in its menu; the source leaves the day on every device and the tutor is told with your next message. Over MCP: `update_review_session_sources` on the day's `memory-YYYY-MM-DD` session.
- **A block's Zoom link is a button.** A web link in a block's notes, which is where a calendar import puts the meeting's conference link, is drawn above the notes as **Join Zoom**, **Join Google Meet**, **Join Teams**, **Join Webex** or **Open \<host\>**.
- **The Planner header keeps two buttons.** The timer that starts a bout, and one ⋯ menu with **Refresh from Calendar**, **New Column**, **Redraw the Rest of the Day** and **Plan the Day in Chat**; the done count stays in the side panel and the Today menu carries the same commands.
- **My Library lists your teams' artifacts beside your own.** The Docs, Sites, Animations and Artifacts homes list what your teams hold as well, each with a small two-person mark naming the team; opening one takes you into that team's library. The Artifacts home now loads its list itself.
- **The Set a goal sheet prompts instead of suggesting.** Its title field says *I want to understand…* rather than a whole example goal.

## 0.60.0 (build 114) — 2026-09-19

**Highlights:**
- **Goals are their own tab.** A Goals row sits in the rail between Planner and Artifacts and opens one list, nearest deadline first, each goal showing how long is left and how much time the last seven days gave it. **Set a goal** is one sentence and a deadline; a Project is optional, and the deadline is what makes a Goal a Goal.
- **A Planner block points at a Goal.** A block's editor gains a **Toward** picker, the card names the Goal, and the side panel's **Toward** rail shows the open Goals by nearest deadline with the time the week drew toward each — nothing is inferred from sources or Projects.
- **Cmd+F finds text on a page in the Browser.** The Browser pane has the readers' find bar: Cmd+F opens it, Return and the chevrons step through the matches, Escape closes it. Ctrl+F stays with the page.
- **Select words on one of your Sites and change them.** The selection bar on a site you published gains **Change**: a sheet with the selected words, Replace writes the new ones into the page and republishes it. The passage must appear exactly once on the page, or ForeverLM says so instead of guessing.
- **Linked in: where a source is used.** A source's context menu and the reader's ⋯ menu list the Docs grounded on it or citing it, the sites whose cards name it and the animations about it, each opening from the menu.
- **A Site published into a team Project stays in My Library.** The team gets a copy of the page at the same address; your own entry stays under your Sites, and a site that had gone missing this way comes back on its next publish.
- **A paywalled Elsevier paper is saved under its title, not "Redirecting".** The DOI's holding page carries no citation; the title now comes from Crossref, so the paper sorts and searches like any other.
- **Scheduling a source that is already on the Schedule for another goal now tags it to the new goal.** `assign_learning_journey_sources_to_day` with a `goal_id` no longer moves the day and forgets the goal.
- **A first robustness pass.** A failing database step is reported instead of silently shortening a list; a malformed numeric argument over MCP is refused instead of crashing the app; `save_animation` reads only files in the folders every other tool may read; a YouTube Short and its watch page are one source.

## 0.59.0 (build 113) — 2026-09-19

**Highlights:**
- **The block you are in, in every window.** A Now chip in every window's titlebar, and in a pop-out Reader's toolbar, says which block the clock is in and how long it has left: filled while the hour is on what the block named, hollow in open time, amber once ten minutes have gone elsewhere, a timer while a bout runs. Click it to open the block's sources and Project, start a bout, mark it done or skipped, give it fifteen more minutes, or answer the drift. Settings › Appearance › **Announce block changes** (off by default) also posts a notification when the clock crosses into a block that named its material.
- **A Site or page shared with a team is the page.** Sharing a ForeverLM site, an animation, a Claude artifact or a Codex site with a team, or filing one under a shared Project, left the team a Doc holding one line of the entry page. The team's copy now keeps the address, lists under the team's Sites or Animations and opens the page; sharing a rebuilt site updates the one entry; a ForeverLM site you published is opened to the team's roster.
- **Sources travel with what you share.** Share a Doc, site or animation with a team and the sources it carries or cites go into the team's library with it, files included, instead of being offered one sheet at a time.
- **Signing out lets a different Apple Account sign in.** The sign-in sheet no longer reuses Safari's Apple session, and the stored identity that provisions the MCP tunnel leaves with the session. The website's navigation gains a **Sign in** link.
- **A private Site opens from a browser again.** Signing in to a private Site or animation from Brave or Chrome ended on "There is no page here"; the access page kept a referrer policy that hid the origin from the Site host, the host refused a token minted a second ahead of its own clock, and a Site's own stylesheets and scripts were bounced to sign-in. All three are fixed and deployed.
- **The Artifacts gallery has no "All" chip.** The gallery opens on everything; the chips are the four kinds, and pressing the selected one again clears the filter.
- **Double-click an empty hour on the Planner to draw a block.** It draws an hour from the nearest quarter hour under the pointer and opens its editor; close that untouched and the block is gone again. A single click on empty time still draws nothing, so the click that puts an editor away never leaves a block behind.
- **Undo on the "Hid …" toast.** Hiding a paper, a book, a channel, a show, a chat, a meeting or a course now offers **Undo** in the banner that reports it; one Undo restores a whole batch.

## 0.58.0 (build 112) — 2026-09-18

**Highlights:**
- **Select an author in a reader and read everything they have written.** Selecting a name — a byline, an author in a reference list — adds a **Scholar** action to the bar over the selection, and it opens that author's Google Scholar results in the Browser pane, beside the paper when the reader is pinned. It appears only for selections that read as a name, and a drag that clips the last letter of a surname still finds the right author.
- **Planning tomorrow is the day's last block.** Every day the planner draws now ends with a short *Shut down · plan tomorrow* block, and the card that used to ask for a plan in the morning is gone. Days already past are left as they are.
- **A paywalled paper reads on the publisher's page.** A paper ForeverLM could not download opens as the publisher's own page in the reader, laid out as the publisher set it, instead of as stripped text — in the pop-out Reader window too. A publisher's *Download PDF* button no longer leaves an error over a page that loaded fine.
- **A re-imported paper takes back its place on the Schedule.** Deleting a paper and importing it again returns it to the day it was scheduled for.
- **Your teammates see your own name.** A roster row shows the account name ForeverLM greets you by, rather than the "You" placeholder CloudKit leaves behind for the signed-in account.
- **Assistants working the same Mac get in each other's way less.** Reads against the knowledge base now run together instead of queueing behind one another, and a call that takes a while is no longer reported to ChatGPT or Claude as a tool that does not exist while your Mac is still doing it. The connector's published surface is the app's own list of tools, all 136 of them.

## 0.57.0 (build 111) — 2026-09-18

**Highlights:**
- **Learning bouts put a clock on a stretch of learning, and the write-up earns the break.** Start a bout on a Planner block and the side panel gives it a timer. It ends when you say what you learned and what you still do not understand — and that write-up, never the clock, is what earns the rest that follows. A bout past its time keeps running and says how far over it is; nothing ends it but you. The break is a minute for every nine minutes learned, from five up to twenty, so a ninety-minute block earns about ten. Letting a bout go is always allowed, and earns nothing. ChatGPT and Claude can start, end and write up a bout too, because the reflection is usually a conversation rather than a form.
- **The Planner asks about the hour it is in.** When ten minutes of a block's hour have gone to things the block did not name, a card appears with three answers and no verdict: *This is the work* attaches what you are reading to the block, *Draw it a block* gives the real work its own time, and *Leave it* silences that one block for the day. A block that named no sources or Project is open time, and nothing in it can be off — so how strict the day is, is something you set when you plan it.
- **A morning without a plan is asked about once.** If the day has no block of your own, a notification in the window's top-right corner asks for one at launch. It waits there until you answer or close it, and closing it means not today. From two in the afternoon it asks about tomorrow instead, and the shutdown now offers **Plan tomorrow…** — so a day planned the night before never sees the morning ask at all. A morning of imported meetings does not count as a plan.
- **`/plan` now plans your day.** In a chat, `/plan` opens the day on the Planner (add `today` or `tomorrow`), and `/today` says what is on the clock right now. The Learning Journey keeps everything it had under `/journey`. The chat reads your day, calendar, Goals and recent work before asking anything, then draws the whole day in one go.
- **Your break has a timer on your iPhone.** The Home screen and the Today widget draw a live countdown for the running bout and its break, on the Lock Screen as well, and the phone notifies you when the break is over. Back to work can be pressed from the phone. The phone shows a break once the app is opened rather than the moment it starts.
- **An hour spent in ChatGPT or Claude lands on the clock where it happened.** A conversation imported into ForeverLM can carry the times it actually ran, and is drawn on the Planner's log at those hours instead of at the time you imported it.
- **The week counts what each Project really took.** Under the day's log, the side panel now shows, over the last seven days, the minutes each Project was given against the minutes its own material actually took. A Project the week gave nothing is still listed, and says "no time this week".
- **Animations: see how something in a source works.** Ask the chat to animate a mechanism from a paper, or `/animate`, and it draws one as code you can play, scrub and toggle. Claude and Codex can save one into your library through the plugin. Animations are hosted exactly as Sites are and stay linked to the sources they explain.
- **Docs, Sites, Videos and Animations fold under one Artifacts row.** The sidebar's top block is New chat, Planner, Artifacts, Browser. Artifacts opens a home with everything in it and filters by kind; the four rows fold underneath and keep whatever you had hidden.
- **Refuse a podcast show before a single episode is imported.** `Never Import <show>` sits beside Follow on a podcast's menu, and Remove All now blocks the show as well, so a music mix does not walk back in with the next episode played. Blocked shows are listed under Hidden Items with Import Again, and the list follows your account to your other Mac.
- **Zoom meetings are the transcript, never the recording.** The download-and-transcribe fallback is gone — it never once produced a usable transcript — so ForeverLM waits for Zoom's own. For meetings Zoom no longer transcribes, a helper transcribes a local recording on your Mac and files it the same way, using Zoom's own caption file when it left one. And the folder it watches is now a setting, shown in Sources settings with a count of the transcripts actually in it.
- **A cancelled meeting leaves the plan at once.** Delete a meeting in your calendar and come back, and the block goes without waiting out a cooldown. When a whole recurring series is cancelled, the side panel offers to clear the days ahead as well. A filed Zoom transcript now attaches itself to the block that meeting occupied.
- **A click on empty time in the Planner no longer draws a block.** Only a drag draws one, which is the gesture that says how long it is. Add Block (⇧⌘D) is still there when you want an hour without drawing it.
- **A long message you paste into a chat folds instead of freezing the window.** Anything over about two dozen lines shows its first six with a line count, a Show all toggle and a Copy button.
- **Papers no longer get stuck behind a cancelled cleanup.** An interrupted pass leaves the paper queued instead of retiring it with an error, and anything already parked that way heals itself with no Retry, no refetch and no second model bill.
- **Errors name the right service.** A request that never reached a provider now says ForeverLM could not be reached, instead of blaming a provider it never got to.
- **Your reviews show as a grid of days.** Clicking Memory used to list earlier reviews as a column of dates. It now draws half a year as a square a day — the colour deepens with the minutes you actually spent, a square with a review in it opens that day, and today's is outlined. No streak is counted out beside it: a week off is a gap in the picture, not a number to lose.
- **Claude and ChatGPT can run today's memory review.** The review that knows which concepts are due was only ever reachable inside the app; asking an assistant for it started an ordinary review instead. It is now a tool they can call, so "do today's memory review" works from Claude or Codex and the grades count.
- **Assistants see your whole library.** A tool call from ChatGPT or Claude now goes to your Mac whenever it is reachable, rather than to the cloud mirror, which lags it — on one day the mirror knew 3,002 sources against the Mac's 4,120.
- **Your own OpenRouter key talks to OpenRouter directly,** so a call it pays for no longer depends on ForeverLM's proxy being up, and the cost shown is the one OpenRouter billed rather than an estimate. Settings › Billing now also says truthfully what your key covers: with OpenRouter it pays for read-aloud voices and speech-to-text as well as text.
- **Notion links copied today work.** Notion moved to `notion.com`, and both link parsers now take it.

## 0.56.0 (build 110) — 2026-09-14

**Highlights:**
- **A site's links to your sources open in Reader, and read as ordinary links everywhere else.** Link a source in a published site by its own web address — its DOI, arXiv, publisher, YouTube or podcast page — and ForeverLM draws the library's card for it and opens Reader in the app. Outside ForeverLM, and for an address your library does not hold, it stays the plain link the page wrote, so a site written for the open web still reads right.
- **Find Linked Sources in a web article.** An article's ⋯ menu and its sidebar context menu read the article's links for the sources they point at — other articles, papers, videos, podcast episodes — and list them with the site, the kind and one line on what the article says about each. Add the ones you want one by one, or ask the chat to "find all the linked sources" and name the ones to add.
- **Choose whether models that train on your data are offered at all.** Settings › Data & Privacy now reads *Don't show models that train on my data*. Leave it off and every model is offered, with a row that trains saying so beside its price; switch it on and those models disappear from every picker. Meta's discounted Muse Spark Contributor tier is back in the catalogue either way, so the choice is yours rather than made for you.
- **A discounted model shows what it would have cost.** The list price is struck through beside the price you actually pay, so a discount is never mistaken for the full rate.
- **Hidden docs, sites and chats are the same on every Mac.** A doc, site or chat you hide on one Mac is hidden on every Mac signed into your account, and the ones each Mac had already hidden are brought together.
- **Your settings follow you between Macs more completely.** How a video sits beside its transcript, how much of the pane it takes, and which rows you have hidden or folded away in the sidebar now travel with your account like the rest of your preferences, instead of being set again on each Mac. Your existing choices are carried over as they are.
- **Reach the open page when the list is hidden.** With the Sites or Docs list collapsed, the pane header now names the page it is showing — click to rename it, drag it straight into a chat beside the pane, or right-click for the row's own actions.
- **Changing a published site touches only the files that change.** A chat asked to rework one page no longer reads back and re-sends the whole site. And when a plugin such as GitHub is not connected, the chat shows a card under the step that opens Settings → Plugins, instead of sending you to sign in through the Browser.
- **Docs link to each other and are easier to find in.** Type `[[` to link another doc from the keyboard, and a published page follows those links; a doc whose first heading is its title shows the name once; Cmd+F finds in a doc's rendered page too; a linked Google Doc that is slow or fails to load says so, with Reload.
- **Voice replies travel lighter.** A loaded source's text no longer rides in every realtime voice reply; the tutor reads passages on demand, so replies start sooner.
- **Connections say what they are doing.** The claude.ai connector lists ForeverLM's tools and keeps its session, and X's Connect button shows that it is connecting while macOS brings up the sign-in window.
- **Planner blocks drag cleanly.** A block just drawn no longer vanishes when dragged, and a moved block holds its new spot until it lands.

## 0.55.2 (build 109) — 2026-09-13

**Highlights:**
- **A table in a Doc is drawn as a table, and a wide one takes the pane.** A cell holding a link and a few words is a link again, not a source card squeezed into a narrow column, and a table of four or more columns spreads past the prose column to the pane's edge so its headings no longer break mid-word. Two- and three-column tables keep the prose column, and the **Page Width** picker in the Aa menu still sets the prose. The web library's editor draws the same.
- **A reopened Doc's source cards keep their picture and details.** Cards in a doc that was closed and reopened, or opened in a second window, showed a bare glyph and a title; they now ask the library again and show their thumbnail, metadata line and check.
- **Drop a source on an empty line in a Doc.** A paper, podcast, meeting, video or book dragged onto a blank line becomes a card in its place, where before nothing happened.
- **Voice shows the tutor at work while it prepares a quiz.** Instead of a still orb over "Listening", the orb thinks and the Mac transcript shows a spinner with the tool's label until the tutor's first words stream in.
- **A sidebar source row's drop outline clears when the drag ends.** The dashed outline no longer sticks to a row after a drop lands elsewhere or a drag is cancelled.

## 0.55.1 (build 108) — 2026-09-12

**Highlights:**
- **Source cards in a Doc are smaller.** A source dropped into a Doc is drawn at the size of the chat's Sources row rather than as a full paragraph: a smaller tile, a tighter line, and the metadata line straight under the title with no empty line beneath it. A card is now about two lines of prose tall where it was nearly four, and a bullet or number beside one is centred on its title again. The web library's editor draws the same card.

## 0.55.0 (build 107) — 2026-09-12

**Highlights:**
- **Drag a source from a chat into a Doc and it becomes a card.** A citation dragged from a reply's Sources list, like a row dragged from the Sources sidebar, now lands on a Doc as the source rather than as its address. Drop it on a paragraph and the paragraph stands on it, as before; drop it between paragraphs or below the last one and it is written as a card of its own, with the library's picture, its title, its author · venue · year line and a check that opens it in Reader. The same drag files the source into a Project, a Planner day or a chat's context, and the web library draws and takes the same cards.
- **Sources added to a running chat show in its transcript.** Dropping articles into an open chat before asking about "these articles" now leaves a folded line on your side of the transcript, "Added 3 articles to context", that opens to the sources by name; the tutor is told the same thing by title, so "these articles" resolves.
- **Clicking Docs in one window leaves the Doc open in another alone.** With two Studio windows, the rail's Docs and Sites rows and a doc opened from a chat or a Project act on the window they were used in; a doc open on your other display stays exactly where it was.
- **A reply's Web sources know a paper you already have.** The Sources list under a web-searched reply now recognises a saved paper by its DOI and by its Nature article id, so a paper saved from a recommendation link or its DOI reads as in your library instead of offering Add to Sources again.
- **The phone retries an iCloud blip once and says what did not start.** Every CloudKit read in the phone's model settings retries once after a dropped connection or a throttled request, and a route that still cannot be resolved names the activity, such as Listen, instead of a generic settings sentence.

## 0.54.0 (build 106) — 2026-09-12

**Highlights:**
- **Chat about, or highlight, a selection in every reader.** Podcast, meeting and YouTube transcripts now show the same **Chat** / **Highlight** bar over selected text that the article, PDF and EPUB readers do. **Chat** adds the passage to a chat (so does ⌘K); **Highlight** saves it with a text-quote anchor measured against the whole transcript, so its context reaches across speaker turns and a highlight saved over MCP from the stored text is painted by its words. Saved highlights are painted into the transcript, a click on one opens its card, the notes list's reveal scrolls to the turn and selects the words, and a plain click on a paragraph of a playing recording still seeks there. The pop-out Reader window's plain-text and PDF views gain the same Highlight, painting and reveal, and the highlight card gains a **Chat** action beside its colours, so a mark is always one press from a conversation about it.

## 0.53.0 (build 105) — 2026-09-12

**Highlights:**
- **Click a picture in a chat to see it full-window.** A figure the assistant showed, a page it screenshotted, an image it drew, or one you attached to your own message takes a zoom-in cursor; a click opens it on a dark backdrop over the whole window. It arrives fitted to the window; click the picture to zoom in around that point and again to fit it back, pinch or ⌘-scroll to magnify freely, and press Escape, ✕ or click beside the picture to close. ⌘C copies the picture, and its caption sits under it.
- **Select words in a reply for Add to chat, More details, or Ask in side chat.** Highlighting part of a reply shows a bar of three actions, and the reply's context menu offers the same three. **Add to chat** puts the passage into the composer as a quote. **More details** asks about it at once, as an aside while a tutor question is open and as an ordinary follow-up otherwise. **Ask in side chat** opens a new chat in the comparison pane with the passage waiting under its composer and this chat's sources attached.
- **The chat shows a figure from any paper in your library.** Ask about a figure in a paper a search just found, and the assistant shows it from the library's own PDF, cropped to the figure, without you attaching the paper first — and without going to the publisher's page. A reference that happened to start a line ("Fig. 2) offers…") is no longer mistaken for the figure's caption, and a label printed twice on one page no longer costs a paper its figure index.
- **Generate Explainer is in the reader's ⋯ menu.** When the reader is too narrow for the toolbar's lightbulb, the ⋯ menu offers **Generate Explainer**, **Rewrite Explainer**, **Open Explainer** and **Cancel Writing Explainer** for the paper or article you are reading — in the inline reader and in a pop-out reader window.
- **Append to an already imported chat over MCP.** `import_review_chat` with a `session_id` now adds the new turns to the imported chat instead of failing on CloudKit's encrypted record; the chat keeps its original dates.

## 0.52.0 (build 104) — 2026-09-12

**Highlights:**
- **A scheduled meeting series is on the Planner every day it meets, with its action items.** Give a meeting series a schedule (weekdays, start, length, time zone) from **Schedule…** on its sidebar menu or over MCP, and its occurrence is drawn on the Planner today and ahead before any recording exists, on the Mac and in the web library. Once a session's transcript is in the library, the new **Meeting Action Items** task reads it once and lists what it asked someone to do under the block, each with a tick that stays ticked everywhere.
- **Ask your assistant where the AI money goes, and let it fix the settings.** Three new connector tools read the AI usage ledger for any period, grouped by task, model and day with the route each task runs on and its catalogue price; read Settings › AI Models as data, catalogue prices included; and change the Default Model, a Background default or one task's override exactly as the pane's own controls do. The plugin's new `ai-cost-review` skill (1.0.5) turns them into a review: it names the tasks behind the spend, proposes cheaper catalogued models or a lower effort tier with the saving worked out from your own per-call token averages, shows the proposal as a table, and applies only the rows you approve. Unpriced calls stay counted rather than guessed, and a model with no known price says so.
- **A paper's cited papers live in the reader's ⋯ menu.** The quotation-mark button leaves the paper reader's toolbar. **Find Cited Papers** in the reader's menu reads the reference list and opens the cited-papers panel off the ⋯ button, where the read's progress and results show; once candidates exist the item reads **Cited Papers** with the number waiting to be added and opens the same panel, whose **Read references again** reads the list once more. The sidebar's context menu keeps **Find Cited Papers**.
- **Settings gains Data & Privacy.** One pane, under Account on the Mac and in the web library, says where your data is and who may keep it: your library lives in your own iCloud and ForeverLM holds no copy; a built-in model request leaves a billing line — provider, model, tokens, cost — and never the prompt or the answer; an MCP tool call is billed by name and count and its contents are not logged, with always-on MCP's hosted cache named as the one exception. It carries the *Don't let AI providers keep my data* switch, which moves there from AI Models › Chat, and a short guide to picking a model that does not train on your data: Anthropic, OpenAI and xAI under their API terms, Google's paid Gemini API, OpenRouter with the switch on, or your own router key. The iPhone's Settings section of the same name carries the same facts.
- **Settings › Connectors › GitHub and Google Drive say what they read.** The GitHub pane draws one card per organisation or personal account the ForeverLM App is installed on, with the repositories it may see there, and offers **Add an Organisation…** and **Disconnect…** from the pane; each Google account lists the meeting folders it reads, with a folder whose account was disconnected set apart.

## 0.51.0 (build 103) — 2026-09-12

**Highlights:**
- **The Planner draws several Google accounts at once.** Settings › Connectors › **Google Calendar** gains **Add Google Account**, each account its own Disconnect, and every account's calendars listed beneath it with a switch each; a calendar shared into two accounts is read once. The account already connected is kept.
- **Meetings that overlap sit side by side on the clock.** Blocks that share a stretch of time, two calendars' events at one hour or a block drawn over a meeting, are drawn in columns instead of one hiding the other, on the Mac and in the web library.
- **Zoom meeting sessions wait for Zoom's own transcript and pick it up on their own.** A recording whose transcript Zoom has not written yet reads "Waiting for Zoom's transcript" and is asked about again every quarter hour, with nothing to press; the recording itself is transcribed only if Zoom has published no transcript after three hours, or when you choose **Get Transcript**.

## 0.50.0 (build 102) — 2026-09-12

**Highlights:**
- **The Planner draws the Mac's own Calendar on the clock.** Settings › Connectors › **Calendar** turns on the Mac's Calendar app, so every account the Mac already holds — iCloud, Google, Exchange, subscriptions — appears on the clock without connecting anything separately and without Google's unverified-app screen. macOS asks for read access once, then each calendar gets a switch. Timed events become blocks that follow the event when it moves or is renamed; all-day, declined, free and birthday events stay off. The block menu opens the event in Calendar, and over MCP `get_day_plan` reports which calendar a block came from as `calendar_source`.
- **Speech on the iPhone plays at podcast loudness.** Realtime voice and read-aloud narration both run through a speech-gated make-up gain and a lookahead limiter before the speaker, so quiet narration lifts toward the level podcasts are delivered at instead of playing 3 to 10 dB under it, and nothing clips. The stored files, their iCloud copies and the Mac are untouched.
- **Listen on the iPhone starts a downloaded chapter in seconds.** A chapter whose audio already exists now plays from the first contiguous run of chunks instead of waiting for the last one, resuming past a saved position, with the rest arriving behind it. The banner, the playback bar and the mini player say what is happening — "Downloading narration · 12 of 40 chunks · 30% · 40s left", then "Playing · downloading the rest" — and the next chapter of a book is pulled down while the current one plays.
- **Realtime voice on the iPhone reconnects without saying so.** A replacement connection is handed the recent transcript before any microphone audio and is forbidden the "I'm back" sentence: it continues a reply the drop cut off, answers a question it never answered, and is otherwise silent until you speak. A socket that dies under a working audio graph now keeps the graph and the microphone, with the audio from the moment of the drop delivered in order, and an AirPods or CarPlay route change no longer counts as a reason to reconnect at all.
- **The ForeverLM connector in Claude Code stops falling back to an hourly sign-in.** The gateway now lets a rotated refresh token answer for as long as it would have been valid, following the chain of replacements to a live pair, so a session idle for a day rejoins without signing in again.

## 0.49.0 (build 101) — 2026-09-11

**Highlights:**
- **The Planner draws your Google Calendar on the clock.** Settings › Connectors › **Google Calendar** connects an account read-only and lists its calendars with a switch each. Every timed event becomes a block titled by the event, with the Meet link or location as its notes, and follows the event when it moves or is renamed; all-day events, declined invitations and the working-location markers stay off the clock. A calendar block is what the day is fixed around: **Extend** stops at it and the assistant's redraw keeps its time. Over MCP `get_day_plan` returns `calendar_event_id` and `calendar_link` on such a block (schema 109).
- **A paper the AI browser thinks is paywalled offers Mark as Paywalled on its row.** When the browser walks away from an abstract-only publisher page without the explicit purchase text it needs to mark the paper itself, the row under "Papers that need attention" now shows **Mark as Paywalled** beside "PDF needed", with what the browser saw in its tooltip; one click files the paper under "Marked paywalled". Attaching a PDF or text, clearing the paywall status or converting the page to an article retires the suspicion (schema 110).
- **Re-importing a playlist as a course revives the videos an earlier removal dismissed.** A playlist imported and removed before left a tombstone on each video, so importing it again created an empty course and said every video was already in the library. Importing a playlist is asking for exactly those videos: the tombstones are cleared, archived rows are revived, a failure on one video is counted and named, and a course that ends up with nothing attached is discarded rather than left as an empty shell.
- **Hide a Site or a Doc.** A site or doc's ⋯ menu gains **Hide Site** / **Hide Doc** beside Archive. Where Archive is the record's state and travels to every device and team member, Hide is this Mac's own view: the record, its page and its team copies are untouched and nothing syncs. Each home's filters gain **Hidden**, which lists what was hidden with a Hidden badge and offers **Show** from the same menu; the chat's `/doc` and `/site` pickers skip hidden records. Over MCP, `update_doc` takes `is_hidden` and every Doc payload reports `is_hidden` and `hidden_at` (schema 111).

## 0.48.0 (build 100) — 2026-09-11

**Highlights:**
- **Planner blocks are no longer sorted into deep work, shallow work, meetings and breaks.** A block is a stretch of the clock given to one thing, and its title says which. The segmented picker leaves the block editor and the browser's dialog, every block draws in one tint, and the day's measure is the minutes done of the minutes planned. **Extend** pushes every later planned block along, and the assistant's redraw reads what is fixed with other people from a block's title. Over MCP `kind` leaves `add_time_block`, `update_time_block`, `revise_day_plan` and `get_day_plan`, whose `deep_work_minutes_planned` and `deep_work_minutes_done` become `minutes_planned` and `minutes_done`.
- **A Planner block holds several sources, and starts a chat with them in context.** Drop sources on a block to add them; drop several on an empty hour and one block carries them all. The card shows a chip per source it has room for, the editor lists them, and **Chat** on a card, in its menu, in the editor and in the browser's dialog opens a fresh chat with the block's sources as its context and an unsent line naming the block. Schema 108 adds `time_blocks.source_ids`; the three block tools take `source_ids` (the old `source_id` is still read) and `get_day_plan` returns `source_ids` and `source_links`.
- **A block drawn and then closed untouched is gone again.** A press on the clock or **Add Block** opens the editor over a new block; closing it without an edit drops the block, and any edit keeps it.
- **The Planner's log reads under the names things carry now.** A paper saved from a download and named later, a chat retitled, a Doc renamed: each span shows the current name in the pane, the side panel and `get_day_plan`; a thing since deleted keeps the name it was seen under.
- **The Planner's clock holds the whole day.** Midnight to midnight, scrolled to the working hours when it opens, so an evening block can be drawn without the grid running out.
- **Google Drive connects more than one Google account.** Settings › Sources › Google Drive adds an account or folder beside each connected account and disconnects one account at a time; every folder and file remembers which account it belongs to.
- **A course's row spins while its lectures are imported**, where its item count will be, from the moment the import knows which course it is for until it finishes.
- **A quoted passage sits above the composer.** Quoting a passage from a reply no longer pastes `> ` lines into the field; it is drawn as a quote above the words, with its own ×, and goes out ahead of the message as the blockquote the bubble draws.
- **Meeting icons and Web Studio pictures can be drawn with GPT Image 2.5 Flare and Sunburst**, priced from OpenAI's published table; GPT Image 1 Mini stays the default.
- **A YouTube video whose captions cannot be fetched shows the failure**, with **Retry Transcript** in the reader and **Get Transcript** in its right-click menu, instead of sitting under Processing.
- **A site or doc dragged onto a chat joins it**, also when its own pane is open beside that chat.

## 0.47.0 (build 99) — 2026-09-11

**Highlights:**
- **A chat too long for one tool call imports whole.** `import_review_chat` gains `session_id`: import the first chunk plainly, then pass the id that call returned with each further chunk and its turns are appended after the stored ones. The session keeps its title, `source_ids` on a chunk join the session's and are marked reviewed, a summary, score or model given on a chunk replaces the stored value, a retried chunk identical to the stored tail is acknowledged and not stored twice, and an unknown id is refused rather than starting a new session. The hosted service appends the same way and needs no `source_ids` for a chunk.
- **The plugin (1.0.4) gains a chat-export skill.** A conversation held with another assistant comes into ForeverLM as a chat, never as a Source; the Markdown it produced becomes Docs linked as `foreverlm://doc/<id>`, the works it cites are linked as `foreverlm://source/<id>` after each is confirmed, a long chat continues with `session_id`, and the stored transcript and every link are verified before the export is called complete. The Gemini CLI extension (1.0.3) carries the same skill.
- **A web article blocked by a publisher's security check finishes from the reader.** When the hidden fetch is answered by a bot check and the reader shows the article anyway, the reader's page becomes the source's content. Earlier builds archived the check's own page as the source's document, which kept the reader's page from ever replacing it; that archive is no longer kept, a source parked as blocked drops it, and a row still carrying one from an earlier build heals the next time the reader shows the article. The hidden fetch also waits up to thirty seconds once a check has started clearing.

## 0.46.0 (build 98) — 2026-09-11

**Highlights:**
- **Notion is a connector.** Connect it at app.foreverlm.com/notion-connect, tick the pages and databases the connection may read, and a chat or an assistant searches and reads them through five new MCP tools (`search_notion`, `get_notion_page`, `list_notion_databases`, `get_notion_database`, `query_notion_database`). Read-only by construction; nothing read is stored.
- **The Planner's log reads by thing.** The day's lane draws one card per sitting, tinted by the kind of work that took most of it, with the minutes actually logged banded inside, glances folded into a count, and a **What you did** list beneath, on the Mac and on the web.
- **The Planner opens on today.** An app left running overnight no longer shows yesterday; the pane selects today on every appearance and moves on at midnight unless you put it on another day.
- **Slack is managed in Settings.** Its Connectors row says **Connected** with the rest of the list instead of seconds later, and the Slack pane is now the connector's home: connect a workspace in a sheet, flip its channels, or disconnect it, without leaving the app.
- **The Videos row hides like the rest of the sidebar's top rows.** Right-click **Videos** and choose **Hide Videos**; **Show in Sidebar** on the Projects header brings any hidden row back. Build 97 shipped the row without that item.
- **Hide any source from its right-click menu.** A podcast episode, paper, article or video hides with **Hide**, above **Remove…**, and a multi-selection hides as one with a single toast. Hiding is now purely visual: the row leaves the list and the source stays in chat, search, reviews and the MCP tools.
- **A hidden show or channel stays quiet for the AI.** Hiding a whole podcast show or YouTube channel keeps its episodes out of chat, search, reviews and the tools, except an episode you bring back from Hidden Items, which returns to both the list and the AI.
- **Hide a whole book from the Books tab.** Select a book and press Delete, or right-click it: the confirmation names the book and offers **Hide Book** and **Remove Book**, instead of acting on the chapter it would resume.
- **Settings › Sources from an assistant.** The MCP contract adds `get_source_settings` and `set_source_settings`, which read and flip each source family's **Search & AI** and **Tab** switches exactly as the pane does.
- **The Background model works again with Ramp Router off.** Paper ingestion and every task following the Background model reported *AI is not configured* after 0.45.0 held Ramp off; a stored Ramp pick is served by OpenRouter, and every stored Ramp Router selection moves back to OpenRouter by itself.
- **No Explainer row in the sidebar.** The indented row under a paper or article is gone; the explainer opens from the Reader's Explain button and from **Open Explainer** and **Rewrite Explainer** in the source's right-click menu.
- **Share with Team lists only your teams.** **New Team…** is gone from the submenu; teams are created from the library switcher or Settings › Account › Team.
- **EPUB chapters keep their names.** A book whose table of contents only lists page spreads (*Pages 12–13*) now takes its chapters from the book's real contents page instead of arriving as dozens of chapters named after page numbers.

## 0.45.0 (build 97) — 2026-09-10

**Highlights:**
- **Import a real EPUB through MCP.** The public catalog gains `import_epub`: an assistant hands over the original file (15 MB at most) and the book arrives as a book, chapters and pictures intact, instead of flattened text through `add_source`.
- **A chat no longer dies when a lab is momentarily refusing a model.** A Gemini 3.8 Flash chat used to end in a red "Provider returned error (429)". The managed proxy now lets a standard-speed request move to the same model's other endpoint when one refuses, and drops a sampling knob (temperature, say) that one of a model's endpoints does not take, so that second endpoint stays reachable. When a lab does refuse, the error names the lab and its reason. A Fast or Flex pick still runs only on the tier it names.
- **Ramp Router is off for now.** Ramp deactivated the shared key, so every text request goes through OpenRouter until the route is switched back on; a Ramp policy on an account is kept but not acted on.
- **A chat can show a video's slides.** Ask for the slide that shows a point and the chat runs the reader's slide capture as a tool, then shows the slide it found.
- **The model picker prices a model at the speed it is set to, Flex is back, and the newest model leads each group.** Prices follow the chosen speed's endpoint, the Flex tier is listed again beside Standard and Fast, and each maker's most recent release sorts first in Settings and the picker, from OpenRouter's own release dates.
- **A trackpad pinch zooms one chat panel.** The chat under the pointer changes size; a chat window on another display keeps its own.
- **Copy Name on Sites and Docs, and a GitHub mark on repository-backed Sites.** A Site or Doc row's right-click menu copies its name, and a Site built from a repository shows the GitHub mark on its row.
- **The Feeds pane says what its Project toggles do.**

## 0.44.0 (build 96) — 2026-09-10

**Highlights:**
- **A chat can use the Browser.** Ask a chat to open a page, and it works in a tab of its own in the Browser pane — under any profile you have signed in with — clicking, typing, pressing keys and turning pages with real input, so it reaches what a plain fetch cannot: a Kindle book at read.amazon.com, a paywalled journal, a Google Doc, a page drawn by scripts. While it works, the activity row shows a small live picture of the tab; click it to open the tab in the Browser. **Take a screenshot** shows you the page as rendered in the answer and, on a model that reads images, lets the chat see it too — so "take screenshots of every page of this book" turns the pages and shows each one. Signing in stays yours: the chat asks you to sign in in the Browser pane and never types a password or payment detail.
- **The Browser says when a page wants a passkey, and offers the page in your browser.** Passkeys in the Browser pane wait on an Apple entitlement ForeverLM has requested; until it arrives, a sign-in page that asks for one shows a notice under the toolbar with **Open in Brave** (or your default browser), where the passkey works. The notice disappears by itself in the first build that carries the entitlement.
- **`/site-prompt` writes the prompt that builds a Site elsewhere.** Type `/site-prompt` in a chat, with an optional focus, and the tutor replies with a prompt in one code block, ready to paste into Claude, Codex or any assistant that has the ForeverLM connector: it opens with *Use the ForeverLM connector to make a ForeverLM site that explains …*, spells out what the chat worked out, lists the sources as `foreverlm://source/<id>` links so `publish_site` draws them as source cards, and names the Project the Site should be filed under.
- **After a side question, the next message is a follow-up.** The Side question token used to leave the composer with the message it marked, so the next thing typed went to the quiz as an answer — and a message sent while the side question's reply was still being written could never be a side question at all. The token now stays until you answer or skip the tutor's question, or take it off, and a follow-up typed mid-reply queues as a side question and joins the lane.
- **A queued message's × sits beside it.** The × that hands a queued message back to the composer was drawn at the far left of a wide transcript, nowhere near the message; it now sits against the bubble.
- **Web citations to pages you already keep are library citations.** When a web-searched reply cites a page that is already a source in your library, the inline citation now opens your copy — drawn as the numbered citation and source card any library source gets — instead of linking out to the web. The Web sources list under the reply still shows the page as Added.
- **An explainer sits under its source.** The "Explainer: …" rows are gone from Articles. A paper or article that has an explainer shows it as an indented **Explainer** row directly beneath, with its length and listening time, in the Mac sidebar and in Web Studio; it opens, plays, drags and removes like any source, and leaves with the source it explains. The source's right-click menu offers **Open Explainer** and **Rewrite Explainer**. On the iPhone the lists leave explainers out and the source's lightbulb reaches them as before.
- **Sites holds only sites.** A Doc you publish on foreverlm.com stays in Docs, with its Published badge and address, instead of moving to Sites and back on every Publish and Unpublish. Sites now lists the sites published from ForeverLM and the Codex sites and Claude artifacts you link, nothing else; its **ForeverLM** filter is those sites alone. The Docs home's **Published** filter is back beside All, Drafts and Archived.
- **Open a Site in another window from the Site itself.** The ⋯ menu in an open Site now offers **Open in Other Window**, whether the Site is linked from Claude or Codex or published by ForeverLM. It uses the same window picker as every other pane, opens a second Studio window when there is none, and keeps that specific Site open there. Open Docs gain the same header action for consistency.
- **Explainer videos.** A new **Videos** row in the navigation rail, beneath Sites, holds short films ForeverLM makes about a concept: say what to explain in your own words, optionally pick a paper or article to ground it, choose a length (three, five or eight eight-second scenes), and the writing model storyboards it while Google's Veo 3.1 films each scene with its own sound and a narrator's voice. The film plays in the Videos pane and wherever the source opens, with the storyboard underneath and a link back to the source; its narration is the source's text, so it searches and reads on the phone like any other source. The exact price is quoted before anything runs and asked every time — scenes times eight seconds times Google's published rate at the resolution you chose in **Settings → AI Models → Videos** — and a scene Google could not finish is not charged. **Generate Explainer Video…** in a paper's menu starts one about the paper, and `/video` followed by a concept opens the composer from the chat.
- **Muse Spark 1.2 Contributor is gone from the picker.** Every chat on it failed with OpenRouter's "Paid model training violation (account settings)": Contributor is Meta's cheaper tier whose discount is paid in letting Meta train on what you send, and ForeverLM's routing account never sends prompts to hosts that train on them. Your Muse Spark 1.2 selection is untouched; a saved Contributor selection asks you to choose another model rather than quietly billing the full-price tier. The refusal itself now reads as a sentence about what the model does with your data, whether or not **Don't let AI providers keep my data** is on, since that switch could not have helped.
- **A Site can be public.** `publish_site` takes `visibility: public`, and the Site opens for anyone with its address: no sign-in, cached at the edge, visible to search engines. New Sites stay private, an update that leaves visibility out keeps the current choice, and switching either way signs every open browser session out of that Site. A paywalled source PDF still attaches only to a private Site.
- **Select text on a Site and take it to a chat.** Selecting a passage in an open Site raises **Add to Chat** and **Copy**. Add to Chat opens a new chat beside the Site carrying the passage, its page and heading, and the Site itself, so the tutor can fix the Site's files and republish to the same address. Copy puts a prompt for Claude or Codex on the clipboard.
- **Rename a Doc or Site.** **Rename…** sits at the top of a Doc's or Site's ⋯ menu, on the Mac and in Web Studio. It renames the library entry; the linked page keeps its own title.
- **Sending a pane's source to another window closes the pane.** Open in Other Window from the Reader used to leave a "Continue reading" pane behind; when the Reader was the pane's visible tab, the pane now folds into its neighbour or gives way to Chat.
- **Connector sign-in returns straight to your app.** Signing the ForeverLM connector in from Claude Code or another local client no longer stops at a "Signed in to ForeverLM" page; the browser hands the sign-in back to the app directly.
- **`include_source_files` belongs to `publish_site`.** `publish_doc` no longer lists the parameter, which it never read; `publish_site`, which has always used it, now declares it.

## 0.43.1 (build 95) — 2026-09-10

**Highlights:**
- **Explainers on iPhone.** A bulb beside every paper and article says where its explainer stands, and a tap does what comes next: dim when there is none yet (tap writes one and starts its audio), filled once the script exists (tap generates the audio and plays it as it arrives), accent-coloured once the audio is ready (tap listens). The reader has the same control beside Listen, with Open Explainer and Rewrite Explainer on a hold, and Cancel while the writer works. An explainer written on the phone is the one the Mac's Explain button opens, and one written on the Mac plays on the phone whether or not the Mac ever generated its audio.
- **Explainers read as essays.** An explainer opens in a measured serif column under a masthead: what it is, the title of the paper or article it explains, how many words and about how many minutes it takes to hear, and a link back to the source. Notes, highlights and find work exactly as before.
- **Follow up on a side question, or take it to a new chat.** The card under a side question now has two rows. **Follow up** asks more in the same lane while the quiz keeps waiting; **New chat** lifts the side question and its replies into a chat of their own, in the same Project with the same sources, where the tutor holds nothing back. **Back to the question** is still there underneath. Follow-ups join the lane instead of starting a new one, so a whole detour folds to one heading, and the heading folds it at any time.
- **A pane's scroll bar can be dragged again at the edge of the center area.** Take hold of the scroll bar's knob in a chat, Doc or Site pane that borders the sidebar or the Sources pane and it scrolls, where before nothing happened: an invisible strip down each edge of the center area, there to turn a dragged tab into a new pane, was taking the click before the scroll bar saw it. Dropping a tab or a source at the edge works as before.

## 0.43.0 (build 94) — 2026-09-10

**Highlights:**
- **Cancel an explainer while it is being written.** Explain used to put up a passing "Writing an explainer of …" notice and nothing more, so a write nobody wanted any more ran to the end and was saved. The notice is now a banner that stays while the writer works and carries **Cancel**; the Reader's Explain slot shows the same small × beside its spinner that Listen shows while audio generates, and the source's right-click menu offers **Cancel Writing Explainer** in place of the greyed "Writing Explainer…". Stopping saves nothing — a source that already had an explainer keeps it — and a reply the model sends after the cancel is dropped rather than saved.
- **Flex, and a price on every speed.** On the OpenRouter route the composer's Speed submenu gains **Flex**, OpenAI's lower-priority tier at about half the Standard price, listed cheapest first beside Standard and Fast; a Flex pick names OpenAI's flex endpoint on the wire the way Fast names the fast one, and the chip shows a tortoise while it is on. Every speed now quotes its price and promotion from the endpoint list the app actually routes by: in build 93 Fast could open without a price and Standard fall back to the list price, because the submenu decided its rows from one copy of that list and priced them from another. A speed pick also survives a failed fetch of that list instead of quietly dropping to Standard.
- **The model menu's price is the one OpenRouter charges.** GPT-5.6 Sol read "$5 in / $30 out · 50% off" while OpenRouter was charging $2 in / $10 out with the discount already inside: the live price lookup keyed the alias `gpt-5.6` instead of the `gpt-5.6-sol` row the request is routed to, and Anthropic's dashed versions missed their dotted rows the same way. Both lookups now build the same slug.
- **A memory review can grade the conversation it opened with.** When today's review took a recent chat as material, the tutor asked about it and then stopped: "the grader rejected the source as outside today's review list", because the review's record listed only its papers and articles, and a chat is not one. The record now carries the whole material list, chats included, on the Mac and on the phone, and a review prepared before this build reads the chat back off its own briefing when it is opened.
- **Only the OpenRouter models on sale.** Settings → AI Models → Browse OpenRouter models gains a **Discounted** chip beside the search field. On, the list is every tool-capable model OpenRouter is currently running a promotion on, biggest cut first with the "N% off" badge each row already carried, and search narrows within it; it is the same set as the discount filter on openrouter.ai's model page.
- **A Site's source card opens in the other window again.** Right-click a source card on a Site and Open in Reader, Open in New Window and Open in Window 2 now do what they say; in build 93 the menu closed and nothing happened, because the item's action arrived after the menu had already let go of it. The Reader's own Open Link, Open Link in Browser and Download Linked File on a right-clicked link were dead the same way, and work again.
- **Archive a Site or a Doc.** A site or doc's ⋯ menu gains **Archive Site** / **Archive Doc**: the record keeps its body, its page and its Project links and only leaves the list. Each home's filters gain **Archived**, which lists what was put away, shows it with an Archived badge and offers **Restore** from the same menu; the chat's `/doc` and `/site` pickers skip archived records. Over MCP, `update_doc` takes `is_archived` and every Doc payload reports `is_archived` and `archived_at`. The archive date travels with the record across devices (schema 106).
- **Drop a source on the Planner.** Drag a paper, chapter or any source row onto the Planner's clock and a deep block for the reading is drawn where you let go, ninety minutes long and titled with the source; drop it on a block instead and that block becomes the reading's. The block shows the source as a chip that opens it in the Reader beside the Planner, its menu gains **Open Source** and **Remove Source**, and the editor shows the source with an open and a remove control. Over MCP, `add_time_block`, `update_time_block` and `revise_day_plan` take `source_id`, and `get_day_plan` returns it with a `source_link`. Schema 107 adds `time_blocks.source_id`.
- **The Planner logs your day.** Beside the blocks, a lane draws what ForeverLM saw you actually do: a paper open in the Reader (reading, or listening and watching for a podcast or video), a chat you were having, a Doc you were writing — each span titled and timed, and each a link that opens the paper, the chat or the Doc. The Deep work section adds a line of what was logged, kind by kind. The log is recorded a minute at a time from the reader's existing engagement heartbeat, chat turns and Doc saves; a pause longer than ten minutes starts a new span, so lunch shows as a gap. It rides in the day's record to your other Mac and reads back over `get_day_plan` as `log`, and it never marks a block done: the plan and the day sit side by side, and the judgement stays yours. Schema 107 adds `day_activities`.
- **The Docs and Sites list toggle moved to the left.** The button that hides and shows a pane's list of docs or sites now sits at the pane's leading edge, ahead of its title, where the window's other collapse controls are, instead of among the actions at the top right.

## 0.42.1 (build 93) — 2026-09-10

**Highlights:**
- **Open a Site's source in another window.** Right-click a source card on a Site and choose Open in New Window, or Open in Window 2 when a second window is already open, and the paper opens in that window's Reader while the Site stays where it is, full screen on one display with the reading on the other. Open in Reader keeps opening it beside the Site, and the card's menu no longer offers to download a link that is not a file.

## 0.42.0 (build 92) — 2026-09-10

**Highlights:**
- **Copy a chat's link.** A chat's sidebar menu gains **Copy Link**, which puts `foreverlm://chat/<id>` on the clipboard. Opening the link resumes the chat in the app; pasting it to Claude or Codex working through the ForeverLM plugin lets them read the chat over MCP — `get_review_session_transcript` and every other tool that takes a `session_id` accept the link as given, and a chat still in progress returns its turns so far.
- **The Papers tab no longer has an Import from Zotero or Paperpile button.** Moving a reference-manager library into ForeverLM is done with an assistant: the ForeverLM plugin's paper-library-migration skill imports each paper through the normal pipeline. The Papers tab keeps **Upload PDFs…** and the drop target.
- **Use the native app.** Web Studio is temporarily unavailable. `app.foreverlm.com` now links to the Mac download, while connector authorization for Slack, Linear, GitHub, and hosted MCP remains available for the native app.
- **A Site shows your sources as the library's own cards.** A page that links a library source (`foreverlm://source/<id>`) gets the same banner the Sources sidebar draws — the source's own thumbnail, its title, author · venue · year — on the web as well as in the app. At publish the Mac renders the thumbnails and stores them with the site's files, so a chat no longer has to draw its own; a card opens the source's public page in a browser and Reader beside the site in the app. Ask for the papers themselves and each linked paper's stored PDF travels with the site, so the web card opens the paper and keeps the publisher link; a paywalled PDF only joins a private Site.
- **Pick a speed, and see what it costs.** On the OpenRouter route the composer's model menu gains **Speed: Standard / Fast** for models whose lab publishes a fast-processing endpoint on OpenRouter (GPT-5.6 Sol, GPT-6 Astra, Claude Opus and Fable, among others). Each speed is listed with its own input / output price from that endpoint, a Fast request targets the endpoint explicitly with fallbacks off, and a bolt on the model chip shows Fast is on. The menu also names OpenRouter's current promotion beside a price ("· 50% off") instead of leaving the discount unexplained.
- **Mention a connector with `@`, like in Claude.** Type `@` in the chat composer and the popup offers your connected connectors — `@slack`, `@linear`, `@github` — with their marks; `@slack what did #general discuss` sends your words as typed and the model reads Slack live for the answer, and a bare `@slack` asks about recent activity. The `/slack`, `/linear` and `/github` commands and the small connector marks under the composer are gone; the mention can sit anywhere in the message, and a name that is not connected is ordinary text.
- **Published Sites are private.** Opening a ForeverLM Site now requires the owner's Apple sign-in. A Site filed in a team Project also opens for accepted team members, and removing a member invalidates their Site session when the roster refreshes.

## 0.41.0 (build 91) — 2026-09-09

**Highlights:**
- **Follow feeds, not just journals.** Settings → Journals is now **Settings → Feeds**: paste the home page of a Substack, a Medium publication, a WordPress or Ghost blog, an arXiv listing, a subreddit or a journal, and ForeverLM finds its feed — trying the conventional paths (`/feed`, `/rss`, `/feed.xml`, `/atom.xml`, `/index.xml`) when a page advertises none. New posts are judged for your Projects on the same terms as papers, each with its source named; housekeeping posts are never suggested. Suggestions appear as **New from your feeds** in a Project's sources.
- **Ask a connector from the chat composer.** Type `/slack`, `/linear` or `/github` followed by your question and the model reads that service live in this turn; a bare command asks a sensible default (recent Slack activity, your open Linear issues, the Project's repository). Small marks under the composer show which connectors are connected and start the command with a click. Study chats offer `/slack` only, since they carry only the Slack tools.
- **Connectors say what they read.** Settings → Connectors names each connection's scope once connected — the X account whose bookmarks are imported, the YouTube source and followed channels, the Google Drive folders, the Slack workspaces and how many channels in each, the Linear workspace and user, the GitHub login and organisations. Web Studio's Connectors panel says the same.
- **Search one field only.** Start the sources search with `title:`, `author:`, `journal:`, `year:`, `doi:` or `site:` to confine it to that field; a bare query still searches everything, including the indexed text.
- **Zotero or Paperpile: a one-time import instead of a connector.** The Zotero or Paperpile connector is gone. Choose **Import from Zotero or Paperpile…** at the top of the Papers tab to copy a Zotero data folder, a BibTeX or RIS export with its PDFs, or a folder of PDFs into your library once; your reference manager is read, never changed. The docs explain why a paper has to live in your iCloud library before ForeverLM can search it, read it aloud or review you on it, and the ForeverLM plugin (1.0.3) gains a skill that walks an assistant through the same migration.
- **A removed meeting stays removed.** A meeting session or series you remove is no longer brought back by a Zoom notice forwarded to the recordings mailbox, a connector re-pushing its history, or a folder refresh; only re-adding it yourself in the app brings it back.
- **Codex sites are Sites.** A `….chatgpt.site` page — and any Claude artifact, ForeverLM site or Google Doc — pasted, dropped, shared from the phone or sent over MCP is linked in Sites (or Docs) instead of being scraped into an article, which for a Codex site would have been its sign-in page.
- **Planner polish.** The block editor opens under the block at the point you clicked and stays inside the clock, sizing itself to its controls so labels are never cut; the Running behind card says when a long-past block ended ("ended 11:30 · 9h ago") instead of counting hours over, and the side panel's spacing, chips and notes field are tidied.
- **Highlights open beside the mark.** Clicking a highlight opens its card as a popover on the mark itself, with the comment field ready, instead of at the top of the reader.

## 0.40.0 (build 90) — 2026-09-09

**Highlights:**
- **Plan your day in time blocks.** A new Planner tab draws your day on a clock: press or drag on empty time to block it for deep work, shallow work, a meeting or a break, move and resize by hand, and mark blocks done as you go. When the day slips, **Redraw the day** asks your model to redraw the rest of it as a new column, keeping meetings fixed and deep work first; the earlier columns stay readable. Close the day with **Shutdown complete**. A chat, Claude or ChatGPT can read and draw the plan too, and Web Studio shows the same day. Its commands live in a new **Today** menu in the menu bar: Open Planner (⌘D), Add Block (⇧⌘D), New Column, Redraw the Rest of the Day, Plan the Day in Chat, Start Today's Review, and Shut Down the Day.
- **Explain a paper, out loud.** Beside **Listen** on a paper or article, **Explain** writes a spoken explainer — why the work matters, what the authors set out to find, how, what they found and what it changes, about seven minutes long — saves it as its own source next to the original, opens it, and narrates it with your read-aloud voice, cost alert and all. The sidebar's **Generate Explainer** does the same, and rewrites an explainer you already have. The explainer is an ordinary source: it syncs to your iPhone with its audio, and it goes when the paper goes. Claude or ChatGPT can ask for one with `generate_explainer`.
- **A chat can publish a real website.** Ask a chat for a site and it publishes HTML, scripts included, at `sites.foreverlm.com/<your-slug>/` — a one-page site or a whole folder, inline or straight from a GitHub repository you have connected. Each site runs in its own sandboxed origin, apart from your account, and appears in your Sites section beside your published Docs.
- **Side questions live on the reply.** The pinned question row and the Answer / Side question switch are gone. While the tutor's question is open, its footer gains a side-question icon: one click puts a *Side question* token in the composer, the aside is answered without giving the open question's answer away, and the next Return answers again. ⌥Return still works.
- **Listening no longer goes quiet after the opening.** The second audio unit is requested together with the opening and units ramp up in size, so playback continues without the gap after the first chunk; if a unit is still on its way the bar says so instead of "Playing".
- **The phone names the narrating model, and follows the Mac's pick.** Generating audio on iPhone shows which model is speaking, and the read-aloud model and voice you choose on the Mac are the phone's too. The first-sync welcome now fills an iPad.

## 0.39.0 (build 89) — 2026-09-09

**Highlights:**
- **Ask a side question in the middle of a quiz.** While the tutor's question is open, the composer pins it beside an **Answer / Side question** switch (⌥Return always sends a side question). The aside is answered, not graded, a **Back to the question** card brings the quiz back, and once you have moved on the aside folds to a heading you can reopen.
- **Keep your prompts off hosts that keep them.** A new switch, *Don't let AI providers keep my data* (Settings → AI Models → Chat on the Mac; Settings on iPhone), routes every OpenRouter request only to hosts that neither retain prompts nor train on them. A model with no such host says so, and you can pick another or turn the switch off. It follows your account.
- **Click a citation to see the passage.** Clicking a `[1]` in a chat opens the source and flashes the passage the claim came from for a few seconds, without saving a highlight.
- **Long books scroll and jump.** The reader's scroll bar can be grabbed on a 1,500-page book, the toolbar counts pages instead of chapters for a PDF book, and **Go to Page…** (⌥⌘G) jumps to a page by number.
- **Retrieved sources read as cards.** A source the tutor pulled into context shows as a card with a readable passage instead of the model's raw text.
- **Pictures come from pages that have one.** When the tutor shows a figure from a paper or book, only a page with a figure caption or a real picture on it qualifies, so a title page no longer stands in for a diagram.
- **Table-of-contents "chapters" are refused.** A book whose split produced a hundred one-page chapters named after contents lines is refused at import with the reason, instead of being written to your library.
- **Quoting an equation keeps the line whole.** Quoting a passage with an inline equation no longer splits it across lines; the equation comes back as the TeX the reply used.
- **Zoom cloud recordings arrive by mail.** Forward Zoom's "Meeting assets are ready" notice to `recordings@foreverlm.com` (a Gmail filter can do it for you) and the recording lands in the right meeting series on your Mac.

## 0.38.0 (build 88) — 2026-09-09

**Highlights:**
- **A reopened chat keeps its sources.** The paper you dropped into a chat stays in the model's context when you reopen the chat, whether you moved it into a Project since or left it for a week; before, it came back as a title the model had to ask for. Moving a chat between Projects while it is open now updates the Project chip and its files in place.
- **Book chapters stop citing the table of contents.** A chapter whose title had run on into the next chapters' headings is now cited under its own heading.

## 0.37.0 (build 87) — 2026-09-09

**Highlights:**
- **Ask a teammate for a paper a team Doc cites.** When a Doc shared with your team cites a paywalled paper that only its author holds, the card now offers **Request**; the author sees **Share** on the same card and a banner above the Docs home listing what only they can answer, and one click copies the source into the team, file included. Sharing a Doc into a team offers to carry the cited sources the team lacks up front, so most requests never need to exist. Over MCP: `request_share`, `list_share_requests`, `fulfil_share_request`, `decline_share_request`, and `include_cited_sources` on `share_with_team`.
- **Link a Project to its GitHub repository.** GitHub is the third connector after Slack and Linear: authorize once at app.foreverlm.com/github-connect, install the ForeverLM app on each organisation you want read, and a chat, Claude or ChatGPT reads repositories, files, code search, issues, pull requests and commits as you, read-only. A Project carries its `owner/repo` from the inspector's **Repository** section, and a chat in that Project knows which repository to look at. **Settings → Connectors → GitHub** shows the connection.
- **Slack reads every workspace you connect.** A second Slack workspace no longer hides the first: channel lists say which workspace each channel is in, search runs across all of them, and app.foreverlm.com/slack-connect gains **Connect another workspace…** and **Disconnect this workspace**.
- **Team Doc cards answer to the team library.** A source card in a team Doc checks the team's copies, not your private library, so every member sees the same cards, and **Add to Sources** on a team Doc files the paper into the team.
- **PDF highlights are just the mark.** A highlight in the PDF reader no longer sprouts a speech-bubble glyph at the end of every line or over the words; the yellow mark alone is the note, and clicking it opens it.
- **Signing in is sturdier.** The Mac app's Sign in with Apple hand-off no longer fails when the browser drops a cookie during two-factor prompts, a blocked Apple pop-up says why instead of "[object Object]", and Web Studio opens a brand-new Apple Account's library instead of "Studio unavailable", walking you through iCloud when it refuses.

## 0.36.1 (build 86) — 2026-09-08

**Highlights:**
- **Doc links open where you are.** A `foreverlm://doc/…` link from Codex, a chat or the Terminal now opens in the Studio window you already have and brings ForeverLM forward, instead of adding a window behind the app you were in. Those background windows could not show Publish, Update Page or Move to Trash; that is fixed with them.

## 0.36.0 (build 85) — 2026-09-08

**Highlights:**
- **Linear, read-only.** Connect a Linear workspace at app.foreverlm.com/linear-connect and ask a chat, Claude or ChatGPT about an issue, a team or a project: ForeverLM reads Linear as you, with the single `read` permission, and never creates, edits, comments on or assigns anything. Six tools: one issue with its comments, a text search, a filtered list (team, state, assigned to me, recently updated, project), the teams, the projects, and one project with its issues and recent updates. **Settings → Connectors → Linear** shows the connection and opens the page; **Disconnect Linear** there revokes the grant.
- **Make a linked site your own.** A Codex site or Claude artifact in Sites can become a ForeverLM page in one step, from its ⋯ menu or with `adopt_page` over MCP: the page is published on foreverlm.com and from then on you, the chat, Claude and Codex edit it here. The original site is not touched. Linked pages also keep a Markdown copy now, with their headings, lists, tables and links, instead of a flat text dump.
- **Brave's reading list, read properly.** Articles saved in Brave reach the Articles tab with their title, the date you saved them and whether you have read them, exactly as Safari's do; an article you removed from Brave stays removed. If an old version of ForeverLM once asked you which browsers to import from, that answer is retired and Brave is on again; `defaults write com.foreverlm readingListBrave -bool NO` still turns it off.
- **`/site` in the chat, beside `/doc`.** Type `/site` and a few letters to add one of your Sites to the chat's context, the way `/doc` adds a Doc; `/doc` now lists only Docs and `/site` only Sites.
- **Use another account switches instead of starting over.** A linked page's sign-in notice now lists the browser profiles you already signed into, so a second Google account comes straight back; **New Profile…** keeps the fresh-jar route.
- **ForeverLM can be your web browser.** Choose it under Default web browser and links open in the Browser pane; this is also the ground for passkeys in the Browser, which wait on Apple's entitlement.
- **Sites open at once.** A Site draws on the Mac with the same renderer foreverlm.com uses, so the page is there the moment you open it instead of after a round trip to the server.

## 0.35.0 (build 84) — 2026-09-08

**Highlights:**
- **A browser inside ForeverLM.** The rail's new Browser row opens web pages in tabs, with an address bar (⌘L), back, forward and reload. Popups open as tabs beside their opener, downloads land in Downloads, and **Add to Sources** saves the page you are reading, as the browser rendered it when the publisher will not hand ForeverLM the text.
- **Profiles keep sign-ins apart.** Every tab belongs to a profile with its own cookies. Library is the one the readers and paper downloads share; any other profile is the browser's alone, so ChatGPT can run on one Google account while the Google Drive connector keeps another.
- **A linked site can use another account.** A Codex site, Claude artifact or Google Doc in Docs and Sites opens under a **Sign-in Profile** from its ⋯ menu. When it asks you to sign in, **Use another account** gives it a fresh profile and opens the Browser pane on the same address so you sign in yourself; the page picks that sign-in up.
- **Customize source types in one place.** The source tab bar's ⋯ menu ends in **Customize Source Types…**, a popover that pins, unpins and reorders every type; a tab's context menu offers the same beside Unpin.

## 0.34.0 (build 83) — 2026-09-08

**Highlights:**
- **A published page is a Site.** A doc lives in Docs while you write it and moves to Sites the moment it has a page on foreverlm.com, next to the Codex sites and Claude artifacts you link; it still opens as its page with **Edit** and **Update Page**, and it comes back to Docs when you unpublish it. Sites filters by where a page lives: **All**, **ForeverLM**, **Claude**, **Codex**.
- **Edit Docs and Sites from Codex or Claude.** `write_doc` and `edit_doc` take `publish: true`, which updates a published page in the same call at the same address with the same readers. For a linked Claude artifact or Codex site the tools now say the route: edit it where it lives, then `link_page` again with the same address and the new text to refresh ForeverLM's copy, or `unlink_page` to make it an editable doc.
- **Linked sites wear their marks.** A Claude artifact carries the Claude mark and a Codex site OpenAI's, beside the Google Docs mark, on cards, rows and the page header.

## 0.33.0 (build 82) — 2026-09-08

**Highlights:**
- **Sites, beside Docs.** The navigation rail has a new **Sites** row: the Codex sites and Claude artifacts you link into ForeverLM, as cards with **All**, **Claude** and **Codex** filters, a search and **Link a Site…**. Paste a `….chatgpt.site` address or a `claude.ai/code/artifact/…` link and the page opens in ForeverLM as itself, with a read-only text copy that chat and review can read. Docs is for what you write here and for linked Google Docs, and its button reads **Link a Google Doc…** again. Everything you had already linked lands in the right section on its own.
- **`link_page` and `unlink_page` over MCP.** An assistant can put a Google Doc, a Claude artifact or a Codex site into ForeverLM from its link, and pass the page's text along so the copy is there at once; `list_docs` and `read_doc` report `claude_artifact` and `codex_site` kinds. `link_google_doc` and `unlink_google_doc` keep working as the same calls.
- **Updating installs the latest release.** When a newer release appears while an update is already downloaded or staged, the app now discards the older one and offers the newest, instead of installing the old build and immediately asking again.
- **The development build has its own MCP tunnel**, so a Dev build and the installed app no longer take the connector from each other; a Mac that stops answering loses the tunnel within about thirty seconds instead of holding it.

## 0.32.0 (build 81) — 2026-09-08

**Highlights:**
- **Select what you want changed on the page.** Nothing is outlined ahead of time. Select words, a sentence, a paragraph or a run of them, and a bubble over the selection offers **✦ Edit with AI** and **Edit text**. The AI changes only the words you selected; Edit text opens the passage's Markdown with your selection marked.

## 0.31.0 (build 80) — 2026-09-08

**Highlights:**
- **Change a block's words yourself on the page.** The field under a hovered block now has **Edit text** beside **Ask**: the block's Markdown opens in a field, links kept as written, and **Save** (⌘↩) writes it, with **Undo** for a moment. Ask still hands the change to the AI.
- **A launch no longer announces a refused iCloud record it is about to retry.** The "iCloud refused a record and parked it" toast at launch was reporting a record the same launch then saved; it now speaks only for what a launch cannot retry on its own.

## 0.30.0 (build 79) — 2026-09-08

**Highlights:**
- **Edit a Doc on the page you read.** Hover any paragraph, heading, list item, table or profile facet in the Page view and press **✦ Edit** at its corner: describe the change, and the page redraws with the proposal in place under **Keep**, **Try again** and **Discard**. Nothing is written until Keep, which offers **Undo** for a moment; a published page still changes only on **Update Page**. Web Studio's Page view offers the same.

## 0.29.0 (build 78) — 2026-09-08

**Highlights:**
- **The Docs home is a gallery.** The rail's Docs row lands on a home page: **All / Published / Drafts** filters, search, a prominent **New Doc**, and every doc as a card, newest first, with its title, where it is filed or its published address, Draft / Published / team badges and the last edit. Web Studio's Docs destination opens the same home.
- **Edit a published page yourself, or with the AI.** The chrome line reads **Edit** while a page shows and **Update Page** while a published doc is being edited. **Edit with AI** on the selection bubble, or **AI** on the chrome line, proposes a rewrite of the selected passage or the section at the caret, with **Replace**, **Insert below**, **Try again** and **Discard**; nothing is written until you choose, and ⌘Z undoes it.
- **Share a published page with specific people by email.** The Publish sheet's password option is now **Share with specific people only**, with a field for their addresses. A reader types their address on the page's gate and follows the link that arrives by mail from share@foreverlm.com; taking an address off the list shuts that reader out on their next visit.
- **Team Docs: drafts that publish, and two writers never lose an edit.** In a team library a Doc opens read-only; **Edit** takes a private draft, **Publish** merges it back over the team copy and asks before replacing a passage both sides changed, and **Discard Draft…** throws it away. Two members editing one Doc at once are merged line by line.
- **The account menu is shaped like Claude's.** The identity header names the open library, one **Library** row drills into the switcher, and while a team is open an entry named after the team opens its own settings, which now also appear as a **Team** group in Settings. A comped account's usage row reads *Paid for by ForeverLM*.
- **Memory asks before the review takes the window.** Clicking the Memory row, the daily reminder or Today's review puts up the Review mode sheet first; only **Start Review** opens the review, and **Not now** leaves everything in place.
- **A large memory review syncs again.** A review no longer grows to cover a bulk import, and a session too large for one iCloud record travels as an asset instead of failing with "record too large". A chat now vouches only for the sources it cites, so one broad Project question no longer puts the whole Project into the next morning's review.
- **Reader and rail.** A PDF book scrolls and searches as one document; chat lists on the rail show ten rows and then a **Show more** footer; a numbered list in a chat reply keeps its numbers past 9.
- **MCP:** `publish_doc` takes `readers` and refuses `password`; `list_docs` reports `published_restricted` and `published_readers`. Web Studio's chat gains `list_docs`, `read_doc`, `write_doc` and `edit_doc`.

## 0.28.0 (build 77) — 2026-09-07

**Highlights:**
- **A short description on every Project card.** Under a Project's title there is room for one or two lines about it: add it from the Project page's **Description** section, from the New Project sheet, or on the phone. It is display copy for you, separate from the Instructions that guide chats inside the Project.
- **Unpin a Project from the sidebar without archiving it.** **Unpin from Sidebar**, on a Project folder's right-click menu, its gallery card's menu and its overflow menu, takes the folder off the rail and nothing else: the Project stays on the Projects page, in selectors and in Today. **Pin to Sidebar** brings it back into place.
- **Docs: the doc's controls sit on the pane's chrome line.** The published address, Page or Edit, the formatting menu and the overflow moved up beside New Doc, and Page view starts right under them; opening a published doc no longer flashes "cancelled" before the page appears.
- **Chat zooms to one panel of a figure.** Asked for Figure 1A, the chat now shows that panel enlarged rather than the whole composite, and a whole-figure answer lists the panels it can enlarge.
- **MCP:** `create_project` and `update_project` take `summary`; `get_project` reports it.

## 0.27.0 (build 76) — 2026-09-07

**Highlights:**
- **Add a paper's cited papers to your library.** A paper open in the reader has a quotation-mark button in its toolbar: **Find cited papers** reads the reference list off the PDF, looks each entry up in Crossref and OpenAlex, and lists what it found with **Add to Library** and **Dismiss**. Papers you already hold are marked rather than offered again, decisions sync between Macs, and the reader's menu and the sidebar's context menu offer **Find Cited Papers** too.
- **Closing the find bar clears its match.** A word found in an article no longer stays boxed in gray after the bar closes; text you selected yourself is left alone.
- **Reference cards recognise a Nature paper hosted elsewhere.** A Doc's card for a Nature-family PDF served from another site now matches the paper already in the library instead of offering to add it again.

## 0.26.0 (build 75) — 2026-09-07

**Highlights:**
- **Journals: follow the journals you read.** Settings → Journals takes a journal's home page or RSS link; every twelve hours ForeverLM checks the feed and offers new articles that fit a watched Project as "New in journals" in that Project's source pool, with Add and Dismiss. Read the details at /journals.
- **Voice starts while AirPods connect.** Starting realtime voice in the seconds after AirPods take over the Mac's audio no longer fails with an audio-device error; the app waits for the devices to settle and retries, and says what happened if they keep changing.
- **The library switcher lives in the account menu.** The rail's top is New chat and Notepad again; My Library, each team and the team commands sit in the bottom-left account menu, whose badge names the open team.
- **A refused team says why.** When iCloud declines to create a team, the Team pane shows the reason under the field instead of a silent nothing.
- **Papers show the real ingestion phase.** An uploaded PDF's row no longer reads "Attaching PDF…" for the whole pipeline; it names the phase the paper is actually in.

## 0.25.0 (build 74) — 2026-09-07

**Highlights:**
- **Teams: a library several people share.** Create a team in Settings → Account → Team, invite people through Apple's sharing sheet, and switch between My Library and each team at the top of the navigation rail. Share with Team copies sources, Projects, Docs and chat transcripts into the team; every Project gains a task board with statuses, assignees and due dates. Read the details at /teams.
- **Podcast episodes from private feeds get the real transcript.** Episodes an older build had filed under their web page held only show notes; they now resolve to the public episode and receive Apple's transcript, and show notes are never treated as an episode's content.
- **The word Feynman is gone; the feature is a review.** Review sessions, the tutor and the chat tools all say review now, in the app, in storage and in the MCP tools (`import_review_chat`).
- **A chat can edit a Doc in place.** Asked to integrate or fix something in a Doc, the chat now changes that Doc with `edit_doc` instead of writing a new one, and tells you when a published page needs republishing.
- **Published pages offer Add to library only for real sources.** Company sites, press releases and bare links stay as links; a profile's sources fold away under a disclosure.
- **A memory review's question can be taken to a chat.** Discuss in new chat opens a chat beside the review with the exchange as context, without grading another attempt; the review's × takes the click in a docked window.
- **MCP: seven Teams tools.** `list_teams`, `create_team`, `share_with_team` and the four task tools, desktop-only.

## 0.24.0 (build 73) — 2026-09-07

**Highlights:**
- **Dictation comes back faster.** After you stopped speaking, the transcript waited on billing bookkeeping that had nothing to do with the words: the server held the text until it had polled for an exact cost, and the Mac wrote its own ledger before showing it. Both now happen after the transcript is on screen, and the connection is opened while you are still talking. Every request also records how long it took, so slowness can be read from the ledger instead of guessed at.
- **Papers from a publisher you are signed in to download through the reader.** nature.com hands its PDFs only to a browser, so a paper your subscription covers showed its full text in the reader while the download behind it failed and the paper sat as "Metadata incomplete". When ForeverLM's own download comes back with a page instead of the file and you have opened that publisher in the reader, the app now fetches the PDF through the reader's own session, opening the paper's page and clicking its Download PDF control the way you would. Recheck all on paywalled papers uses the same route.
- **The reader shows a loading bar.** Publisher pages often show nothing for seconds while a bot check or a sign-in page loads, so a working click looked dead and got clicked again. A thin bar along the top of the page now appears the moment a load starts and fills as the page arrives.
- **Chat looks in the paper's PDF before the web.** When you asked about a figure the paper's index did not list, such as a supplementary figure, the chat gave up and searched the web for a picture that was on page 2 of the PDF it already had. The reply now points the model at the paper's own pages first.
- **The context gauge reads the right window.** The GPT-5.6 line was pinned at 256k when it accepts 922k of input, so chats read as nearly full and sources were trimmed that would have fit; Claude Opus 4 and Together's Inkling were pinned too high. The pinned table was audited against the labs' pages and corrected.

## 0.23.2 (build 72) — 2026-09-07

**Highlights:**
- **eLife papers download again.** eLife's pages stopped advertising a PDF link, so an open-access eLife paper sat in Papers that need attention until a bot check stopped the search. ForeverLM now asks eLife's public API for the file, which names the PDF directly, before trying anything else.

## 0.23.1 (build 71) — 2026-09-06

**Highlights:**
- **Papers from publishers you have signed in to download again.** ForeverLM's own downloads carried your reader sign-in as a fixed set of cookies and ignored the ones a publisher sets on the way, so nature.com's sign-in bounce looped until the download gave up with "too many HTTP redirects", and every Nature paper sat in Waiting to find PDF. Downloads now follow that bounce the way the reader does, so a paper your subscription covers comes down as its PDF, and Recheck all on marked paywalled papers can recover it.
- **A paper's supplementary file is never saved as the paper.** Download PDF on a publisher page could pick the first PDF link it found, which on Nature is the Reporting Summary, and file those four pages as the paper. Supplementary information, source data, reporting summaries and peer-review files are now skipped everywhere a PDF is picked or attached, and the reader says so when that is all the page offers.

## 0.23.0 (build 70) — 2026-09-06

**Highlights:**
- **Quote a passage from a reply into your next question.** Select words in a chat reply and a **Quote** pill appears over them, the same bar the Reader shows for a selection; the reply's right-click menu offers **Quote in Chat** too. Either drops the passage into the composer as a quote with the cursor on the line beneath it, so the follow-up is typed under the words it is about. A draft you had started keeps its words and the quote follows them, and the sent message shows the passage as a quote above your question.
- **A paper becomes a paper from its web page only when you ask.** Builds 68 and 69 took the page the reader showed for a paper without a PDF as the paper's text the moment it loaded, and a signed-in reader watched its paper go into cleanup showing a raw page dump. That no longer happens, and the background fetch never reads a publisher's page as the paper either: a paper without a PDF waits in Papers that need attention. For a paper you can read on the publisher's site, the reader's toolbar and menu now offer **Save Paper from Page**: it stores the page's text as the paper, asks the publisher for the PDF once more with your signed-in session, and when the file is still refused prints the page you are reading to a PDF and saves that as the paper's file, so the paper has the PDF everything else expects. The access wall, or a page that is only the abstract, is refused with a message saying so.
- **A publisher's preview is never mistaken for a paper.** Two Nature Neuroscience papers read as finished on the abstract, the figure titles and the Extended Data legends, which run to thousands of words while the paper itself is absent. The full-text check now counts only the body, text already stored that fails it is dropped so the paper asks for its PDF again, and the reader shows the publisher's page in its place. A Nature News & Views piece filed as an article also stays one instead of being promoted back to a paper on every discovery pass.

## 0.22.6 (build 69) — 2026-09-06

**Highlights:**
- **A paper opens on the text ForeverLM has for it.** A paper whose PDF the publisher will not serve now shows its saved text, and only falls back to the publisher's page when there is no text to show. Papers whose full text arrived without a PDF were the ones affected: the reader offered the PDF ahead of the text it already held, and never loaded that text in the first place, so a finished paper could sit behind a lock screen. Signing in to a publisher in the reader also survives the round trip now, so the page that comes back from a login is saved as the paper.

## 0.22.5 (build 68) — 2026-09-06

**Highlights:**
- **Podcast catalogs sort in episode order.** An episode you never played now takes its publish date, so a whole show imported at once lists newest first instead of in the order it was imported. Played episodes still sort by your last listen.
- **A paper you can read stops asking for a PDF the publisher will not give.** Opening one used to end at a lock screen saying the PDF is paywalled, even for a paper you have access to, because ForeverLM's own downloads knew nothing about the publisher you had signed in to in the reader. Sign-ins done in the reader now count for everything the app fetches, the **Download PDF** button in the reader's toolbar included, so a paper you have access to can end up with its real PDF attached. And when the publisher still refuses the file, the reader opens the publisher's own page, where you can sign in, instead of the lock screen.
- **A paper you can read online is a paper ForeverLM can hold, PDF or not.** Publishers such as Nature let a subscriber read a paper on the site without ever offering the PDF, and the paper sat in Papers Needing Attention with nothing to show for it. Open it in the reader, signed in to the publisher there if need be, and once the page in front of you is the paper its text is stored as the paper's content and goes through the usual cleanup and metadata extraction, so search, chat, review and Listen work on it. The background fetch reads the publisher's page the same way when every PDF route fails. A page that is only the abstract and a purchase panel is never taken for the paper, and the row keeps asking for the PDF until one turns up.

## 0.22.4 (build 67) — 2026-09-06

**Highlights:**
- **Follow a podcast show whole.** Right-click any episode and choose Follow: every episode Apple Podcasts holds for the show is imported now, and each new one arrives on its own from then on, played or not. Unfollow keeps what you already have.

## 0.22.3 (build 66) — 2026-09-06

**Highlights:**
- **Follow YouTube channels.** Under Settings → Connectors → YouTube, paste a channel's address or @handle and its newest 50 videos land in a group of their own in the YouTube tab, with every new upload imported automatically from then on. Stop Following keeps what you already have.

## 0.22.2 (build 65) — 2026-09-06

**Highlights:**
- **An article the reader can show is an article ForeverLM saves.** A publisher security check that blocks the background fetch used to leave a row red while the very page sat open in the reader. The reader now hands its loaded page over: the text is stored, the HTML archived for offline reading, and the block lifted, once the page in front of you is the article and not the check. The background fetch also waits out a check that clears on its own instead of taking the interstitial for the page.
- **Hidden shows have a way back.** Every sources list ends with a quiet row saying what is hidden in that tab; click it for Hidden Items, where a show unhides in one click and expands to its hidden episodes. While you search, the row says how many hidden items match, and opening the page carries the search along. Unhiding a show brings back the episodes another device hid alongside it, and **Import All Episodes** in an episode's context menu adds a show's whole catalog from Apple Podcasts, played or not.

## 0.22.1 (build 64) — 2026-09-06

**Highlights:**
- **Opening a long chat from history loads without jumping.** A row above the visible part of the transcript that shrank while you were at the bottom used to push the newest message off the screen, and rows could flash at thousands of points tall for a frame before their real height landed. Both are fixed: the newest message stays at the bottom, and every row opens at its real size.

## 0.22.0 (build 63) — 2026-09-06

**Highlights:**
- **The memory review picks yesterday's sources by how you engaged with them.** Where you stopped is no longer enough: a paper paged to its end in seconds, or a post that fits on one screen, needs time behind the position before it counts as read, and a source you chatted about is consumed whatever the reader saw, is dated to that conversation, and opens the review with what you took away from it. Highlights lift a source a level. What you opened but never got into is named in the briefing as also opened, not reviewed, and never quizzed. The review and the Memory row now open with the day's ledger — sources, time, how many were discussed in chats — so you can check the picker against your own memory of the day. Time is measured while a reader is frontmost and while audio or video plays, on the Mac and the phone.
- **The thumbs under a chat reply teach the tutor.** A like or dislike on a tutor turn is now kept with the exchange, synced to every device and Web Studio, and a dislike asks in one field what was wrong. A background pass, Question Calibration, distils what you rewarded and rejected into a short calibration the review and study prompts read, so the tutor matches the grain of the questions you liked and stops asking the kind you did not.
- **The Review mode sheet says less and can be told to stop.** Two lines instead of three paragraphs, and a Don't show this again checkbox that sticks whichever button closes it.

## 0.21.0 (build 62) — 2026-09-06

**Highlights:**
- **A published Doc opens as its page.** A Doc published on foreverlm.com now opens as the rendered report, with its live address in the header; **Edit** reveals the Markdown source, and the page replaces the editor rather than sitting beside it. The Docs list marks the row **Published** and shows its foreverlm.com/share/ address. Web Studio does the same.
- **See and copy a page's password.** The Publish sheet shows the current share password, with Show and Copy Password, and still replaces or removes it. A page protected before this build keeps its password but cannot show it until you set a new one.
- **Assistants see what is published.** `list_docs` reports each Doc's published state, address and password, and `publish_doc` returns the password it set, so a research agent can hand back a link and the word that opens it.

## 0.20.0 (build 61) — 2026-09-06

**Highlights:**
- **Drop pictures into a chat.** A screenshot from Finder, an image dragged out of a browser, or one pasted with ⌘V waits as a thumbnail above the composer and goes to the model with your next message — or on its own, when the question is "what is this?". The transcript keeps the picture above your words, with Copy and drag-out like a figure from a source. A model that reads text only is refused before anything is sent, with Retry offered once a vision model is picked. Pictures are attached to the message, not imported as sources, and live on the Mac that attached them; another device shows "not on this device" in their place.
- **Find anything in Slack with one search.** A chat asked about something posted in Slack now searches every enabled channel as far back as the workspace keeps, reads the thread a hit belongs to in full, and sweeps channels one by one only when search is unavailable. A channel read pages back through any window up to ten years and says when it stopped short instead of calling one page the whole window. A workspace connected before this build is asked once to **Grant search access** at app.foreverlm.com/slack-connect.
- **A reply with sources no longer jumps as you scroll.** The Sources footer under a cited reply was built only once its cards had been looked up, so the row measured short, grew by a line per source when the cards landed, and did it again every time it scrolled back into view. The row now reserves that space from its first paint, so the transcript stays where you left it.
- **Your own address for a published page reaches the Mac app.** The Publish sheet's address field described under 0.19.0 missed build 60 by minutes; this build carries it, together with the move of published pages to foreverlm.com/share/. Links to the old /d/ addresses forward.
- **A Slack connection follows your account.** When Apple re-issues your Sign in with Apple identity, the Slack installation, the relay address, connector authorizations and the hosted iCloud link now move to the new identity on its first request, instead of Slack showing Not connected and a fresh relay address.

## 0.19.0 (build 60) — 2026-09-06

**Highlights:**
- **A published page can have your own address.** A page on foreverlm.com no longer has to live at twelve random characters: the Publish sheet, Web Studio's Publish dialog and `publish_doc`'s `slug` take an address of your choosing — `foreverlm.com/share/techbio` — when the page is first published or at any update. Pages now live under `/share/`; the `/d/` links already sent forward there. Changing the address of a page already shared moves it, and the old link forwards to the new one for as long as the page is up, so nobody who has the first link loses the page. An address another page already holds is refused.
- **Published pages read like reports.** A research report on foreverlm.com now opens with a filterable directory of the companies it profiles, draws each profile as a block of labelled facets with numbered citation chips, breaks tables out of the text column, and keeps a contents rail beside the prose on a wide screen. Pages are rendered when they are read, so every published page picked this up without an update.
- **Add to library on every published source.** Each source card on a published page carries Add to library, which opens Web Studio with the address filled in, or opens the source when your library already has it. A signed-out reader is told what the sign-in is for and lands in the same dialog afterwards.
- **View a Doc as its page inside the app.** The Docs pane header's View as Page shows the doc exactly as foreverlm.com renders it, published or not, and its Add to library controls file sources straight into this Mac's library.
- **Deep Research opens each company's own channels.** The research agent now reads a company's News, Blog, Research and Publications pages and the Substack or newsletter they link to before relying on search results, treats a technical blog as primary evidence, and names the channels it checked.
- **Searching the Books tab no longer freezes the app.** Typing into the Books search stalled the Mac for as long as the word took to type against a large library; the chapter filter now reads the index the library already keeps, and the search looks inside chapters.
- **Listen on the phone adopts audio the Mac already made.** A chapter the Mac narrated hours earlier no longer says "Preparing audio…" and starts a second generation; the phone waits for the manifest iCloud has announced and plays it, and the resume point follows the account.
- **Deleted course material no longer comes back as a citation.** The exact-word search now skips hidden sources and the same excluded set every other library tool uses, so lectures from a removed course stay out of a chat's answers.

## 0.18.0 (build 59) — 2026-09-05

**Highlights:**
- **A published page can require a password.** A research report shared with a few people should not be open to anyone who is forwarded the link. Require a password in the Publish sheet sets one; readers enter it once on a small form at the page's address and are remembered for thirty days. The site keeps only a salted hash, never the password, so the password is yours to pass on separately from the link; changing it signs every reader out, and updating the page without touching the password keeps it. In the Doc's header the globe becomes a lock. Web Studio asks the same question in its Publish dialog, and `publish_doc` takes a `password`.

## 0.17.0 (build 58) — 2026-09-05

**Highlights:**
- **A Doc publishes as a page on foreverlm.com.** A research report is written to be read by people who do not have ForeverLM, and until now the only ways out of the app were a Google Doc or a CloudKit share to another ForeverLM user. Publish to foreverlm.com… in the Doc's overflow makes it an unlisted page at `foreverlm.com/d/…` that anyone with the link can read. The Doc stays a Doc, with its reference cards, Add to Sources controls and chats, and the page is a rendering of the same Markdown by the site itself: cited sources stay as links, a line that is only a link is drawn as a reference card, ForeverLM's private links unwrap to their text, attached pictures are left out, and no script can run in a reader's browser. Once published the page carries a small globe beside the title, and a Published submenu holds Copy Link, Open Page, Update Page… (the address never changes) and Unpublish….
- **Publishing belongs to your account.** It is tied to the Sign in with Apple in Settings → AI, so only you can change or take down a page, and a signed-out Mac is told where to sign in. Web Studio offers the same actions in the Doc dialog, and assistants get `publish_doc` and `unpublish_doc`, so a research agent that has just written a report can hand back its link. Each account can publish up to a hundred pages of up to a megabyte of Markdown.

## 0.16.0 (build 57) — 2026-09-05

**Highlights:**
- **What you learn in a chat comes back in tomorrow's Memory review.** A chat only nudged which sources the review picked; nothing said in it was ever asked back, so a conversation that worked something out was gone the next day unless a source in the library happened to cover it. An ordinary chat you took part in — not a memory review, not a graded quiz, not a scheduled task's output — now enters the review as material of its own once ForeverLM has said enough in it: its ideas are drawn from the transcript, it is asked back the day after with the same unaided contour a source gets, and it climbs the same ladder on the same grades. The review's brief tells the tutor it is a conversation, so the question is what you took away, not what a source said. The Memory row's count includes chats, and the phone prepares the same review from the same chats.
- **Scrolling a chat no longer jumps.** A chat opened from history landed at its bottom with every row above unmeasured; each opened at one line as it scrolled into view, and the height WebKit then measured was held until the scroll stopped and applied all at once, moving whatever was under the pointer. A row now opens at an estimate from its text, its first measurement lands at once, and a change to any row above what you are looking at is scrolled past in the same layout pass that resizes the transcript, so the content on screen stays where it is — the scroll anchoring a browser does. A reply still streams at full speed, and its resizes still wait while you scroll.
- **A chat on a Project or on a paper can read Slack.** Those chats carry a small tool surface, and Slack was not on it: asked about a PDF posted in a channel that week, the chat searched the library nine times, found the paper's stub and never read the channel. The Project and source chats now list channels, read them live, and attach a posted PDF to the paper it belongs to, with the same guidance the general chat had. The Slack tool rows are named in the transcript.
- **Sources cited inside a Doc's sentences stand beside the paragraph.** A research report an assistant writes cites as it goes — `[Phase 2a paper](…)` at the end of the claim — and those links were plain blue text: to see what a paper was, or to add it, you followed the link out of the app. Every paragraph that links to the web now carries a stack of cards in the right margin, one per source in the order cited, each drawn the way the Sources sidebar draws a row: the picture, the title, a quieter line of what it is (author · venue · year for a paper, the site for a page) and, at the trailing edge, a filled check that opens a source you already have beside the doc, or a plus that adds one you don't through the same import as the reference cards. A source not yet in your library reads its own page's title and metadata — a journal article's citation tags, a company page's title and site name — so the card tells you what you would be adding. Hovering a card underlines the words that cite it. The prose is never reflowed: the stack sits at the top of its paragraph, or steps down past the stack above it when two would collide, and the page moves over to make room for the column — in a pane that cannot hold both, the page narrows first, and in one too narrow for either the cards step aside and the links stay where they were. The Markdown is unchanged, and `create_doc` and `write_doc` now tell assistants that an inline citation earns the same card as a reference line.
- **Reference cards in a Doc carry the source's picture.** A card stood on its title, a detail and the site, which across a research report's hundred and fifty references reads as a wall of titles; every other place that stands for a source — the sidebar row, the References shelf, a chat citation — shows its picture, and now the card does too. A source already in your library shows the library's own artwork: a paper's first page, a chapter's cover, a podcast's art, a video's still. A source you don't have yet shows a link preview — the page's own preview image where the page declares one, otherwise the site's icon, small — so a nature.com card and a company page still tell apart before you decide to add either. A card with nothing to show carries its family's glyph in the family's colour. Previews are fetched once per address for the life of the app and read only the head of a page; an address that names a PDF is never downloaded, and its card shows the site's icon instead. Pictures arrive after the library's answer, from the top of the doc down, so a long report fills in as you read rather than all at once at the end.
- **Slack stays connected across restarts and updates.** The Slack connection lives on your ForeverLM account, but the Mac reaches it with its Sign in with Apple session, and that session lasted thirty days with no way to extend it: a Mac signed in on day one found a dead session at its first launch after day thirty, Slack showed **Not connected**, and every ForeverLM AI request stopped until the Apple sheet was completed again. The app now renews the session itself, at launch and when it comes to the front, once the session is into its second half, so a Mac or iPhone opened at least once a fortnight never lapses. A device left closed for more than thirty days still signs in once.

**Version:** the minor version moves to 0.16.0 because the release adds new behavior to the app; the MCP tool contracts, the knowledge-base schema and the sync format are unchanged.

## 0.15.0 (build 56) — 2026-09-05

**Highlights:**
- **Restart on an update brings back the exact view you were in.** Pressing Restart in the sidebar's update pill reopened the app's layout with fresh panes: the Reader on nothing, the Chat on its welcome screen, Docs on the first doc, Sources on Articles. Each window now also records what it was showing — the source in its Reader, the chat in its Chat pane, the doc in Docs, and the Sources tab — and the relaunched build puts all of it back, with the tab that was in front still in front. The same happens after the Full Disk Access relaunch. An ordinary quit is unchanged, and named workspaces still carry only the arrangement. A Docs pane rebuilt by a layout change also comes back to the doc it showed rather than the first one.

**Version:** the minor version moves to 0.15.0 because the release adds a new behavior to the app; the MCP tool contracts, the knowledge-base schema and the sync format are unchanged.

## 0.14.0 (build 55) — 2026-09-05

**Highlights:**
- **References in a Doc are cards, and a paper you don't have is one click from your library.** A line that is nothing but a link — the reference list under a research report an assistant wrote, an item in a reading list — is now drawn as a compact card: the title, a quieter detail such as `— Nature, 2024`, the site, and what your library says. A source you already have carries a filled check that opens it beside the doc; one you don't offers **Add to Sources**, which files it the same way pasting the address would, shows a wait while a paper's PDF and metadata are fetched, and then turns into the check. Matching uses the library's own identity rules — the address, its DOI including a saved preprint's journal DOI, or its arXiv id — so the same paper linked three ways is one paper. The Markdown stays an ordinary link, so nothing new is stored and the doc reads unchanged everywhere else; the `create_doc` and `write_doc` tools now ask assistants to write references in this shape.

**Version:** the minor version moves to 0.14.0 because the release adds a feature to Docs and changes what the `create_doc` and `write_doc` tool contracts ask for; the knowledge-base schema and the sync format are unchanged.

## 0.13.0 (build 54) — 2026-09-05

**Highlights:**
- **Slack is read, never saved.** A Slack thread could be filed into the library as a source of its own, and that turned out to be worse than nothing: a chat asked about a channel found the saved copy, searched no further, and reported an August thread as the current state of Slack while the September primer sat unread. The Slack source type, its sidebar tab and the tool that filed threads are gone, and the saved threads leave the library on first launch. Slack is one thing now: the connector, which reads an enabled channel live each time a chat asks and stores nothing. A PDF posted in a channel is still filed as the paper it is.
- **The model menu in a chat no longer tells a signed-in account to sign in.** The picker opened on "Sign in with Apple to choose a model" for an account whose chats were going through fine. Every picker began by asking Ramp Router for its catalog before it had read which router the account actually uses; with Ramp's key deactivated that request failed, and the failure emptied a menu that OpenRouter had already filled. The picker now starts from the account's router and asks Ramp for nothing while another router is in charge, a Ramp answer that lands after the router has changed is discarded, and an empty menu says what it means — "No models available right now" — with the sign-in line kept for a Mac that has no ForeverLM AI session at all.
- **A linked Google Doc is all Google's page.** The pane carried a slim row of ours — the Docs mark, Open in Browser and a menu — above Google's own toolbar, and its margins framed the page on all four sides. Google's chrome already names and edits the doc, so the row is gone: the web view starts at the top of the pane and, with the pane to itself, runs edge to edge. Its actions — Add to Chat, Refresh Text Copy, Open in Browser, Copy Link, Reload, Unlink, Remove from Docs — live in the Docs pane header, in the slot the Markdown editor keeps for its formatting menu.
- **Dropping a book into a chat loads as much of it as the model can hold.** Chapters loaded in full until a fixed 64,000-character budget ran out, so a 21-chapter book showed "4 in context" on a 256k-token model. The budget is now half the selected model's input budget, refreshed whenever the model changes and before any source text is loaded; the 64k figure remains only for a model with no published context window.
- **First launch on the iPhone starts syncing straight away, and says what it is doing.** The narration scan used to run before the library sync and, on a phone that had not yet materialised the shared iCloud audio tree, blocked it for as long as iCloud Drive took, leaving the setup screen on "Connecting to iCloud…". The two now run side by side: the library walk starts at once and the narration badges land when the manifests arrive. Once the library is in, the remaining scan reports itself — "Checking for narrations · n of m sources" with a real bar — instead of "Syncing your library" with no numbers behind it.

**Version:** the minor version moves to 0.13.0 because the release changes the public surface: the knowledge-base schema moves to 92, which retires the Slack source type and drops its `slack_messages` table, and the MCP surface loses `add_slack_thread`; `list_slack_channels` and `read_slack_channel` are unchanged, and `get_app_context` is no longer offered to in-app chats while staying on MCP. The sync format loses only the retired Slack tab's pin preference.

## 0.12.1 (build 53) — 2026-09-05

**Highlights:**
- **A PDF posted in Slack now completes a paywalled paper.** Two things stood between the file and the library. A Slack connection made before ForeverLM could read files was answered "not found"; the gateway now says what to do — reconnect once — and the Slack connect page shows a **Grant file access** link that takes you straight to Slack's consent screen. And a PDF that arrived for a paper already listed was turned away as a duplicate even when that entry was a paywalled stub with no file; the importer now attaches the file to that paper, extracts its text and metadata, and clears the paywall mark. A paper that already has its PDF keeps the duplicate answer.
- **The Memory badge counts only a review that is running.** The red badge stood on the rail for any day with something due, before you had started and, for a review that ran before the goal existed, after you were done. It now means one thing: minutes still to go on a review that is on screen, then the flame and the streak. Clicking **Memory** gives the window over to the review — the rail, Sources and the other tabs step aside until it ends, and the review's header carries the countdown and the ✕ that ends it; the first time, a sheet explains this. The iPhone's Memory card reads the same rule.
- **First launch on the iPhone says Get started, not wait.** The first-sync screen was a spinner and a record count on a black canvas, which read as the app being stuck. It is now a welcome with a prominent **Get Started** button; the sync readout drops to a small card beneath it with the step, the live count and a progress bar when there is one.

**Version:** the patch version moves to 0.12.1 because the release fixes and refines what 0.12.0 shipped; the knowledge-base schema, the sync format and the MCP tool contracts are unchanged. Slack's connection gains one answer, `slack_reconnect_required`, on the file route.

## 0.12.0 (build 52) — 2026-09-05

**Highlights:**
- **Memory has a daily goal, and a streak.** The time each day set in Settings → Memory is now also the day's goal: **Memory** in the rail carries a red badge with the minutes still to go, and the badge counts down only while today's review is on screen and you are actually at it — typing, sending, picking a chip, scrolling, or reading a reply as it streams; a review left open on a desk stops counting after a minute and a half. When the goal is met the chat celebrates once, the badge becomes a flame with the number of consecutive days done, and the streak carries across the Mac and the iPhone, which keeps the same clock on its Memory card.
- **A PDF posted in Slack can be filed from the chat.** `read_slack_channel` used to reduce every message to its text, so a paper dropped into a channel as a PDF with no words was not even reported, and nothing could fetch a Slack file: its private address needs the workspace credential, which lives only on the gateway. Every attachment is now listed under `files` with its name, type, size, permalink and a `download_url` that ForeverLM's gateway serves as you, from channels you have enabled, without keeping a copy. From a chat inside the app that address completes a paywalled paper with `attach_pdf_to_paper` or files a new one with `import_paper_from_url`, whose new `source_url` makes the file's permalink the paper's canonical address; the chat is told never to send you off to download the file yourself. A remote assistant can list the files but not file them. The Slack app asks for `files:read` on your own token, so a workspace connected before today reads files through the bot until you reconnect at app.foreverlm.com/slack-connect.
- **An iCloud blip no longer switches automatic audio off on the iPhone.** The phone checks your paid-voice consent before each automatic audio pass and read "iCloud could not be reached" as "consent withdrawn": it tried to turn every automatic audio switch off, that write failed on the same outage, and the failure came up as a warning over your sources saying the setting could not be checked and no request was sent. A pass that cannot reach iCloud now stops quietly, generates nothing, changes no switch, and tries again on the next event; a genuine failure to turn the switches off says what it means.
- **A finished audiobook shows on the iPhone.** In Sources → Books, a book whose every chapter has read-aloud audio — narrated on the Mac, by an assistant, or on the phone — carries the headphones its chapter rows already wear, so you can see which books are ready to listen to without opening them. A chapter whose audio has not downloaded yet still counts; playing it fetches the audio.
- **New Doc and Link a Google Doc are two buttons.** The `+` at the top right of the Docs pane opened a menu with both; now the plus makes a new doc in one click and the Google Docs mark beside it links a Google Doc, so neither is hidden behind the other.
- **Generate a course from a topic.** **Generate**, beside **New Course** in the Courses tab, takes a subject — *mitochondrial transplantation* — and a line about what you already know, searches your library for everything that bears on it, optionally researches the live web and imports the pages it cites, and plans one curriculum over the result. Each module becomes a lecture holding its readings, a written lesson grounded in those sources, and an exercise sheet, all saved as course material you can read, review in review chat, and schedule. Turn on **Schedule** and a Project named after the course is created with one module placed every few days. Two new AI tasks, **Course Planning** and **Course Lesson Writing**, pick their models in Settings → AI Models like every other step. Assistants get the same through the new `generate_course` MCP tool.
- **Leaving a source on the iPhone no longer warns that an operation was cancelled.** Opening an article, post, chapter or a chat about one puts the source on today's calendar with a write to iCloud. Leaving the screen before that write came back cancelled it, and the cancellation was shown as a warning over the next screen — *Source activity could not be logged: Operation … was cancelled*. The write now finishes on its own after the screen is gone, and a write iCloud itself cancels is retried the next time the source is opened instead of being announced.
- **Podcast transcripts read as a conversation on the iPhone.** Each speaker's turn sits under their name with a mark in that voice's colour, the way the Mac's transcript reader lays them out, instead of the `[SPEAKER_2]` and `**Name:**` labels the import wrote being printed as text. The names inferred or edited on the Mac are the ones shown; a show with a single voice drops the repeated label and reads as prose; show notes, chapter headings and anything else outside a speaker's turn render as before.

**Version:** the minor version moves to 0.12.0 because the release adds features and changes the public surface: the knowledge-base schema moves to 91 with one new table, `memory_review_activity`, and the sync format gains one record type, `MemoryReviewActivity`. The MCP surface gains `generate_course`, `read_slack_channel` answers with `files`, `file_count` and a `files_note`, and `import_paper_from_url` accepts an optional `source_url`; every addition is additive and no existing tool contract changed.

## 0.11.0 (build 51) — 2026-09-05

**Highlights:**
- **The review shows where it moves to the next source.** When the memory tutor turns from one source to the next, the transcript gets a heading with that source's thumbnail and title at the point of the switch, and the chip for the source under review is ringed in the strip above and scrolled into view. Until now the strip ticked a checkmark at the top while the question at the bottom changed subject mid-reply, and nothing said which was which.
- **Click a source chip to steer the review.** A click on a chip in the strip turns the tutor to that source: a source already checked off gets a deeper probe, one still waiting is taken next. **Open in reader** is in the chip's right-click menu.
- **Yesterday's reading always gets its first pass.** Today's memory review used to fit the daily time budget by dropping sources, so a heavy day of reading came back as a review of five, most of them repeats. A source you took in since yesterday and have not yet discussed is now always in the review; the budget decides how deep each one goes, and the tutor names anything that did not fit.
- **Reading counts as reading again.** How far you got in an article, paper, book chapter or video is recorded as you scroll, turn pages or watch, so the review can tell a source you read from one you glanced at. Opening a source for a moment records nothing; thirty seconds on screen, or moving through it yourself, does. This had shipped on 2026-08-27 and was lost in a merge the next day, which is why the review saw none of the past week's reading.
- **A day's review is titled by its full date.** The chats under **Memory** in the rail read **5 September 2026** rather than **Memory · 5 Sep**; the row above them already says Memory. Reviews from before this change show the same way.
- **The Read Aloud player sits in the reader.** The playback bar used to span the bottom of the whole window whenever anything was being narrated, even with the chapter open in front of you. It now sits at the foot of the reader that shows the narrated source, and the window-wide bar appears only when that reader is gone — another source opened, the reader closed, Chat in front — so the audio always has a visible pause and stop, and never two sets of controls.
- **A publisher's picture-drawn Δ stays in its equation.** Some EPUBs draw Greek letters and arrows as tiny images dropped into the sentence — every Δ in *The Vital Question*'s ΔG = ΔH − TΔS is one. The reader treated each as a figure and centred it on its own line, so the equation ran to six lines and the paragraph after it broke wherever a delta appeared. An image that sits in running text and is no taller than a couple of lines now flows inline, on the Mac and the iPhone; a chapter ornament or a real figure in its own paragraph is still a block.
- **Back and forward work again while reading a book.** Docked in a Studio window the reader's toolbar sits in the titlebar band, where the back, forward and **Add to Sources** buttons lit up on hover but the click went to dragging the window. They now take the same path as the Contents and close controls beside them.
- **A linked Google Doc no longer repeats its title.** Google's editor already shows and edits the title, so the row above it now holds only the doc's actions.

**Version:** the minor version moves to 0.11.0 because the release adds features — the source headings and chip steering in the memory review, and the memory review's new first pass over yesterday's reading. The knowledge-base schema, the sync format and the MCP tool contracts are unchanged.

## 0.10.0 (build 50) — 2026-09-04

**Highlights:**
- **Ask your assistant to generate audio.** Three new MCP tools let Claude, ChatGPT or any connected assistant narrate your library: `generate_source_audio` takes sources, whole books (chapters in reading order) or every source of a type — "generate audio for all my books" — with the voice chosen in Settings; a run that costs money is quoted first and starts only after you agree, a free voice starts at once. `get_source_audio_status` reports what is generating, queued, ready or failed, and `cancel_source_audio_generation` stops it.
- **A progress panel while audio generates.** The sidebar shows each book being narrated with a bar, the chapter in progress and a Stop button, from the book's **Generate Audiobook** item as well as from an assistant, and reports the tally when the batch finishes. A chapter row shows a spinner in place of its speaker badge while its own audio is being made.
- **A chapter names its book, not a UUID.** The Now Playing line under a chapter's title showed the book's internal group id for imported books; it now shows the book's title, in the player and in the synced audio a chapter carries to other devices.
- **iPhone playback waits for the whole chapter.** A chapter still arriving from iCloud could be handed to the player half-downloaded, which failed with a bare "The operation could not be completed"; a chunk now counts as playable only once iCloud reports it downloaded, so the download bar shows instead.

**Version:** the minor version moves to 0.10.0 because the MCP surface gains `generate_source_audio`, `get_source_audio_status` and `cancel_source_audio_generation`. The addition is additive: no existing tool contract changed, and the knowledge-base schema and sync format are unchanged.

## 0.9.0 (build 49) — 2026-09-04

**Highlights:**
- **A doc can link to another doc or a Project.** Drag a doc from the Docs list, or a Project from the navigation rail, onto an open doc and a link with its title is written where the pointer was. Hover the link for **Open doc** or **Open Project**; the doc comes forward in Docs, the Project opens in Projects, and the same addresses open from a chat reply.
- **A doc's Projects are managed from the doc.** A **Projects** checklist in the ⋯ menu above an open doc, and in a row's right-click menu in the Docs list, files the doc under any Project or takes it out of one. Until now the Projects were set when the doc was created and only the doc tools could change them.
- **Find every source that mentions an exact word.** `search_sources_keyword` sweeps the whole library for a word or phrase as a case-insensitive substring and returns all of it, most mentions first, with passages showing the word in place. Semantic search could not answer this: it tokenizes, so `uncoupler` never matched a paper that only said `uncouplers`.
- **Generate a whole audiobook in one click.** A book's right-click menu has **Generate Audiobook**: one price, one question, and every chapter that still needs audio queued in reading order. Narration was one chapter at a time until now.
- **Open in Other Window works past the Reader.** A doc, a Project, a chat and today's memory review can each be sent to another Studio window, not only a source.
- **A source dragged into the chat no longer opens on the way.** Dragging a video transcript to the composer used to open the video first, with no way to avoid it.

**Version:** the minor version moves to 0.9.0 because docs gain a linking feature, the doc tools' descriptions change, and the MCP surface gains `search_sources_keyword`. The addition is additive: no existing tool contract changed, and the knowledge-base schema and sync format are unchanged.

## 0.8.0 (build 48) — 2026-09-04

**Highlights:**
- **Deep Research works like a research agent.** A visible plan, web search on every step of the reply (up to forty steps), pages and online PDFs read in full with a new page-reading tool, working notes kept in a Doc, and a complete cited report written into a "Research: …" Doc; searches and page reads show as activity rows, and every page searched or read is listed under the reply with an Add button that runs the Reader's "Add to Sources" import
- **A Google Doc can live in the Docs pane.** "Link a Google Doc…", in the menu behind the + at the top right of the pane and in its empty state, shows Google's own editor inside the pane with a read-only text copy for chat and review, and "Convert to Google Doc…" turns a doc you wrote into one; "Unlink from Google Docs…" is the way back
- **The context gauge trusts each model's published window.** The chat's gauge and trimmer use the model's published context window, or none, instead of a guessed default, so GPT-5.6 Sol's 256k window is no longer read as 128k
- **Drop docs and sources anywhere on a chat.** The transcript and the composer both take the drop, and a doc's title can be dragged as well as its row
- **/source and /doc search as you type.** Both commands in the composer search your library and Docs in a popup; "Open in Other Window" is the one way to read a source in another window; Settings → Memory gains a daily time budget the review is planned to fit
- **The chat's doc tools have plain names.** They are list_docs, create_doc, read_doc, write_doc, update_doc, list_doc_chats, link_doc_passage_to_chat and unlink_doc_chat, and the activity rows say "Listed docs" and "Read doc"

**Version:** the minor version moves to 0.8.0 because the knowledge-base schema moves from 89 to 90 (a linked Google Doc's edit URL on a doc) and the chat's doc tools change name; the MCP tool contracts are otherwise unchanged, and the sync format is unchanged.

## 0.7.0 (build 47) — 2026-09-04

**Highlights:**
- Today's memory review is one review on every device: the Mac's Memory row, a new Memory card on the iPhone's Home screen, and "start my review" in either voice tutor open the same chat from the same synced record, with the same plan, words, Go deeper and Next chips, and checkmarks
- The review can be ready before you click: "Have today's review ready" in Settings → Memory on the Mac and in the iPhone's settings prepares the chat at a chosen hour on whichever device is first, with the outcome shown in Settings and a Prepare now beside it; the daily reminder shares the switch and opens Memory
- The first time a review is planned live, the chat offers once to have it ready each morning; the status line now says "Planning today's review", and a source the model cannot turn into ideas is remembered for a day rather than billed again on every click
- The iPhone's item-based "Memory Review" button, its Siri command and its deep link now open the Memory card

**Version:** the minor version moves to 0.7.0 because the iPhone gains a review surface and its preparation. The sync format is unchanged — the phone reads and writes the session, idea and preference records the Mac already wrote — and the MCP tool contracts are unchanged; the realtime voice tutors gain one tool, `start_memory_review`.

## 0.6.1 (build 46) — 2026-09-03

**Highlights:**
- Fixed the Memory row crashing the app as it prepared today's review: a Release-only compiler miscompilation left every extracted source unaccounted for, and the same shape is corrected everywhere it appeared
- GPT-6 Astra joins the OpenAI group of the model picker on Mac, iPhone and Web Studio, with the Extra High and Max reasoning levels it introduces; GPT-5.6 Sol stays the OpenAI default until OpenAI opens Astra to every API account
- The chat rail highlights a chat only while it is showing, so opening Docs or Projects no longer leaves two rows lit
- A grounded passage in a doc is marked by a hairline in the margin rather than a dot beside the bullet
- On the iPhone, every source list has a search field and the reader has Find, and Now Playing shows a paper's first page or the book's cover as its artwork

**Version:** the patch version moves to 0.6.1: nothing in the sync format, the local schema or the MCP tool contracts changes, so the new model and the iPhone search ride along with the crash fix rather than warranting a minor bump.

## 0.6.0 (build 45) — 2026-09-03

**Highlights:**
- A Memory row in the rail, below Docs, starts today's memory review as a chat: one review per day over what you took in yesterday, what is due again, and one bridge from further back. Each source opens with a free recall of its main points, the tutor grades which of the source's ideas came back, and Go deeper and Next chips under the reply let you steer; a source's next review date follows how much of it you produced unaided
- Chat searches the web when a question needs it (on the Anthropic, OpenAI, xAI and OpenRouter routes; Gemini stays off the web), and when a chat brings up a paper the library does not hold it offers to add it and finds the DOI or publisher page itself
- A chat citation into a video, podcast or recording carries the moment (`[2 · 12:34]`) and seeks the player there, and "show me the slide that shows X" works for videos and recordings
- Cmd+F finds text in a doc
- Settings → Connectors says whether Slack is connected, beside X, YouTube and Google Drive
- Scrolling back through a chat while it is still answering is smooth, and a chat opened in a different Studio window than the one you clicked in says so
- Fixed a relaunch multiplying the Studio windows it put back, an accessibility crash on the answer timestamp, a click in the sources list stalling the app, podcast transcript formatting that thought for minutes per chunk, and a paywalled paper import that dropped the paper instead of adding it

**Version:** the app moves from 0.5.0 to 0.6.0 because the release changes the sync format — memory ideas sync as a new record type, and the local schema advances to 89. Every release now changes the marketing version: minor for features or a public-surface change, patch for a fix-only release.

## 0.5.0 (build 35) — 2026-08-31

**Highlights:**
- Every center pane can be closed, including the last one: Docs, Tasks and Projects keep their close control when they are the only pane, and closing one lands on the chat greeting rather than an empty reader
- The chat says what it is doing while it does it, and a turn no longer ends on a promise it never kept when the model's tool call is malformed
- A Project chat can read your own library
- A citation opens in the Reader window that already has the source, and clicking one no longer closes the Sources panel
- The transcript holds still under a scroll already in progress, a doc's paragraphs get their leading back, and the chat's copy button no longer slides under the pane's pin
- The voice screen no longer shows a healthy session its own protocol errors, and the ended voice card no longer carries the model's grading prose
- Dictation uploads the audio it needs instead of four copies of it
- Signing in on foreverlm.com works in browsers that partition third-party storage: the session reaches Studio instead of silently bouncing back to the marketing site
- The navigation rail's trailing icons light up under the pointer, and the desktop no longer shows through the rail

## 0.5.0 (build 34) — 2026-08-31

**Highlights:**
- Fixes build 33, which was notarized but refused to open. Everything below shipped in that build and arrives here intact.

## 0.5.0 (build 33, withdrawn) — 2026-08-31

**Highlights:**
- Zoom joins Google Meet and Gemini in Meetings: one tab per meeting with the provider as a badge, the transcript kept as its own artifact, recording-only and notes-only meetings transcribed, and slides read off the recording rather than only off YouTube
- A meeting session gets a picture instead of a glyph — the thumbnail Drive already made, a frame from a recording already on the Mac, or, once switched on in Settings → Images, one drawn from what the meeting was about
- Slack is now a connector a chat can read: connect a workspace from the web, and an assistant reads the channels you enable
- Reader highlights and notes are open to MCP: an assistant can read what you marked, search every mark in the library, add or rewrite one, and file what it read into the library
- Search matches what you meant: text is analyzed on the way into the full-text index and queries are tokenized the same way, so a hyphen no longer decides whether a source matches
- A source dragged onto a doc attaches to the passage it is dropped on, and the passage's source picker opens on the words it highlighted
- The daily review is drawn from what you actually read or heard recently
- The voice orb is the ForeverLM mark, filling like a pipe while a session connects
- Billing fixes: the comped monthly ceiling is gone, a spent comp falls back to your own balance, one metering failure no longer locks you out of AI, and a call that consumed nothing is no longer counted as spend
- Sync fixes: the library's records arrive before its gigabytes, sync starts once the local library is on screen, a migration-sized backlog is paced so CloudKit stops rate limiting it, and assets are named after their content so rebuilds reuse them
- Sign in with Apple no longer greets you as FeynmanLM, a re-issued Apple identity is handed back the account it left behind, and an existing Keychain vault is actually adopted
- Clearer errors: an unreachable iCloud is no longer blamed on your model settings, a failed provider's raw payload is no longer shown as the error, and the phone no longer shows the same error twice
- Papers keep their own colors in Dark Mode, the reader keeps its loaded page across a remount, Studio panes move on a swap instead of rebuilding, and both side panels are the same width
- Dictation and recording transcription can use different models

## 0.5.0 — 2026-08-29

**Highlights:**
- The product is now ForeverLM, with the iridescent infinity mark. An existing FeynmanLM library, Keychain vault, and iCloud Drive folder are adopted on first launch rather than left behind
- Studio panes can all be pinned at once. Opening something new then adds a third pane instead of stealing one of the pinned ones, and multi-display workspaces are saved and restored
- Replaced the Schedule pane with a plan you can edit and a history of what was actually read or heard, instead of treating every opened source as done
- Renamed Notes to Docs. Sources attach to a passage rather than appearing as chips in the prose: a margin dot marks a grounded paragraph, hovering underlines the covered words, and the References shelf shows only what the selected passage stands on
- Typing `@` in a doc no longer opens source search; `/source` still cites a source by name, and a whole book can be attached as one reference
- Papers and articles follow the reader's dark mode even when the original page has none
- Search from the sidebar looks inside sources, not only titles
- Automatic audio can be filtered in natural language, and X posts archive as offline thread captures
- Google Drive meeting recordings play through the connector session, import shortcuts and native transcript Docs, transcribe recording-only or notes-only meetings, and can discover papers mentioned in the meeting
- Every new account starts with a $1 AI balance, granted once after Sign in with Apple
- Fixed the Docs source picker beachball on open, strict `/source` filtering, empty Google Drive meeting folders, and a host of Studio, reader, CloudKit, and iPhone workflow bugs

## 0.4.4 — 2026-08-23

**Highlights:**
- Prevented large paper and article pages from hanging during metadata extraction when opened or fetched

## 0.4.3 — 2026-08-22

**Highlights:**
- Eliminated CloudKit self-echo sync storms that could stall the main thread and beachball the app
- Fixed Safari Reading List access, reconciliation, onboarding, and ForeverLM-owned read state
- Added shared X authorization with event-driven bookmark refresh
- Added related Project context across Mac and Web Studio
- Improved book file drops, import feedback, cover resume behavior, and contents navigation
- Prevented Finder PDF drops from aborting the app

## 0.4.2 — 2026-08-22

**Highlights:**
- Added **Shallow Read** for a fast, selective grasp of a source and **Deep Read** for careful, source-grounded study, with the same modes on Mac and Web Studio
- Moved iCloud sync status out of the Studio sidebar and into Settings, kept healthy background activity silent, and stopped CloudKit session conflicts from entering a retry loop
- Replaced the oversized update notice with a compact sidebar affordance and showed the crown consistently for every complimentary account
- Repaired mojibake in archived article text across Mac, iPhone, and Web readers, and limited pinch zoom to the reader instead of scaling unrelated app chrome
- Stopped repeated local-file access prompts and suppressed harmless Safari Reading List permission warnings while keeping genuine access failures visible
- Improved source ingestion with reliable Figshare article-title extraction and refreshed Web Studio reader caches for corrected content

## 0.4.1 — 2026-08-21

**Highlights:**
- Added synced highlights and notes to Mac and Web readers, including CloudKit-backed selection restoration and cross-device updates
- Synced archived article reader documents so rich article layouts survive across devices, with stored-text and live-web fallbacks when an archive is unavailable
- Made Apple Podcasts ingestion event-driven and durable: library file changes trigger sync, missing Apple transcripts are transcribed, and queued work resumes after interruptions
- Hardened CloudKit recovery with bounded retries, quarantine for rejected records, monotonic progress, and clearer status messages
- Fixed reader navigation and interaction across Mac and Web, including first-click opening, source reselection, back navigation, pointer-aware pinch zoom, adaptive toolbars, titlebar clicks, and full-screen chrome
- Recorded reading and listening activity consistently across tutor surfaces, including listened book chapters and externally supplied activity dates
- Grouped book chapters under shared artwork in Projects and resolved project covers from the same synced artwork
- Opened Sign in with Apple directly from the Mac app and eliminated transient Full Disk Access warnings
- Read-aloud's default model now declares the 70+ languages Google publishes for Gemini 3.1 Flash TTS instead of claiming every language there is, so unsupported source languages can be routed or reported correctly

## 0.4.0 — 2026-08-19

**Highlights:**
- Read, hear, and answer in the learner's own language rather than in English, with read-aloud recognizing when a source is not in English and narrating it with a voice that speaks that language — asking first when none does, rather than billing for words read with the wrong pronunciation, and letting Vision detect a scanned page's language instead of guessing it
- Made credit arriving the thing that resumes work an empty balance parked, and stopped treating a blank a paper's document never prints as a failed ingestion
- Made read-aloud a first-class way to take a source in: generation survives a dropped connection, continues in the background, resumes where a listener left off, opens with short chunks so playback starts sooner, and states its price — per book rather than per chapter — before it is switched on
- Extended opt-in automatic read-aloud to every reading type, so books and courses are each their own choice alongside articles and papers, and a source the phone cannot narrate yet no longer blocks the rest of the pass
- Rebuilt review around a cohort of what you actually read rather than a deck of ideas, with consumption measured by how far a source was genuinely taken in
- Gave Notepad a clean writing canvas that opens the existing source-grounded Chat beside selected text, plus Obsidian-style Markdown editing and an inline slash-command palette at the caret
- Made saved sources genuinely available offline on iPhone, including papers whose document cannot be reached, with one menu row for downloads and a clear reason when a save fails
- Synced generated audio, course material, and listening completion across Apple devices, and showed iCloud progress as a pie that fills as it catches up
- Added a friends-and-family comp list to managed AI: a named tester's usage is paid for rather than billed, capped at a monthly allowance they cannot raise, with their text models routed through Ramp Router, and a badge beside their name in the sidebar that says what the comp covers this month
- Let an operator add balance without paying, reconciled the server ledger when credits run out, and stopped paying the cache-write premium on prompt prefixes nothing can read
- Removed the one-time $5 promotional starter balance for new accounts. New accounts start at zero balance and must top up before using managed AI. Existing balances and historical allowance ledger entries are unaffected
- Restored an in-app Google Drive connection for meeting folders, with Google's folder picker, narrow `drive.file` access, secure token storage, and event-driven refresh, and taught the reader to open Google Sheets and Slides links
- Published the official Grok Build plugin and marketplace listing
- Stopped the paper metadata gate from withholding a source's own text, stopped calling a resolved paywall "Ready", and let a running batch check be stopped
- Gave the reader link context menus that do what they offer, in books as well as articles, and kept links working in archived web articles
- Separated iPhone and CarPlay chats in the sidebar, stopped stalled CarPlay voice capture safely, and gave iPad a home surface composed for its canvas
- Made an available update announce itself: the Mac app now checks hourly and on every launch rather than once a day, and posts a notification you can click to install, instead of relying on a pill in a sidebar you may have hidden

## 0.3.0 — 2026-08-15

**Highlights:**
- Added a synced Notepad workspace for Markdown artifacts, with autosave, heading-derived titles, slash commands, split-view navigation, direct creation, and bounded Web Studio editing
- Added opt-in automatic read-aloud preparation for ready articles and papers, with synced settings across Mac, iPhone, and Web Studio
- Brought Web Studio and macOS into closer parity across Projects, Schedule, source management, reviews, Deep Research, Calendar export, and reader state
- Shipped the public MCP gateway that Claude, ChatGPT, and Grok connect to, and submitted the shared 25-tool ChatGPT and Codex plugin for review
- Made hosted MCP a complete Learning Journey control surface, including review transcripts and correct Project completion when scheduled work is reopened
- Improved iPhone Project, Schedule, source archive and revival, listening, reading, and cross-device relationship behavior
- Distinguished listened sources from read sources across library filters and progress
- Removed orphaned image, diagram, static flashcard, retired provider, and dormant overnight-audio paths
- Fixed portable URL and DOI identity convergence plus Project, Schedule, activity, chat, artifact, and review relationship preservation across clients
- Removed the direct Meta API starter-credit trial; Muse Spark remains available through the managed first-party Meta route
- Added one account-wide Ramp Router switch that narrows Settings to Ramp's active, fully priced catalog and keeps exact fail-closed cost accounting

## 0.2.0 — 2026-07-21

**Highlights:**
- Made pricing purely usage-based: the app is free to download with nothing to unlock or subscribe to — you pay only for the AI you actually use (provider API rates + 15% in the app, 1¢ per MCP tool call), drawn from one prepaid dollar balance with a $5 free allowance for new accounts, optional auto top-up, and per-chat costs visible in the context gauge
- Consolidated every AI call onto OpenRouter as the single rail — one searchable model directory with live list prices grouped by maker, covering chat, transcription, and text-to-speech; retired the Cloudflare AI Gateway hop and the direct DeepSeek, Moonshot, and Together hosts
- Redesigned Studio navigation: a left rail with per-project chats, source tabs in the titlebar band, center tab groups you can drag and split like an editor, a docked chat panel, and a Projects gallery page
- Rebuilt Projects around outcomes: timebound Goals created through chat, standing Instructions the model follows in every Project chat, key research questions as a first-class attribute, and a Goal path that reads straight off the Schedule (the separate AI-planned day arc is gone)
- Upgraded chat: web search, slash commands, live markdown streaming, visible tool-call chips, a rolling history summary with automatic tool-result compaction, and no per-turn tool ceiling
- Hardened the chat harness: native tool calling, typed errors, full-turn cancellation, transient-failure retries, and fixes for lost replies and dead-end turns
- Wired prompt caching for every provider that discounts it, and surfaced cache and context-window usage in chat and settings
- Moved semantic search fully on-device (Apple embeddings fused with full-text search), with one shared ranking for the app and MCP
- Improved readers: a color theme setting that now defaults to light (no more inverted PDFs and articles), back/forward navigation, click-to-expand figures and tables, "Chat about this" on selected text, and Zoom recording transcripts
- Fixed a long list of main-thread hangs: chat switching, file pickers, CloudKit refresh stalls, sidebar and reader iCloud file checks, and text-selection freezes
- Added X posting, Google Docs drafting over MCP, meeting-file session grouping, and content fetching at ingestion so sources are ready the moment they're opened

## 0.1.0 — 2026-07-13

Versioning restarted at 0.1.0 to adopt proper semantic versioning. Earlier releases used a retired numbering scheme and have been unpublished; this release supersedes all of them (existing installs update to it normally).

**Highlights:**
- Added Meta's Muse Spark 1.1 as a text AI provider via the new Meta Model API — add a Meta API key in Settings and pick Meta for chat or background tasks (Meta's consumer chat app doesn't support MCP connectors, so it can't connect to ForeverLM directly)
- Added Gemini as a Read Aloud provider, with overnight batch audio generation at half price
- Added one-click approval for MCP connections in the app and a redesigned pairing consent page
- Made Sign in with Apple the primary unlock: your license follows your Apple ID, with self-serve device management and key recovery
- Overhauled read-aloud reliability: per-paragraph generation with retries, synced playback position, sleep timer, AirPods/system media controls, and a playback scrubber
- Moved the Google Drive connector to file-picker scope and YouTube to a ForeverLM-owned OAuth client
- Hardened the MCP server: hosted relay only, stricter auth, and friendlier client names
- Added an AI support agent on the website that can file GitHub issues for licensed users
- Added custom source ordering in Project pools and read-status/content-status filters in the sources sidebar
- Fixed several main-thread hangs (app launch, sidebar, EPUB chapter loads, thumbnail cache)
