---
layout: doc
title: In-App Chat
---

# In-App Chat

The Chat panel lets you review sources inside ForeverLM instead of opening Claude, ChatGPT, Gemini, Grok, or Edison Scientific. It uses the chat model you choose in **Settings → Chat**, run through OpenRouter, so you can keep the whole learning loop in one app while still choosing which model processes your data.

## What Chat does

Use in-app Chat when you want to:

- Ask questions about selected sources
- Run a source-grounded review
- Start today's Schedule work without switching apps
- Run today's [Memory review](#memory-review) from the **Memory** row in the rail
- See your Goals and Ideas: ask "what are my goals?" or "what are my ideas?" and the chat lists them; `/goal` sets a new goal
- Save the review session back into ForeverLM automatically
- Keep a transcript that future sessions and Studio can inspect

Chat is source-grounded. Add sources to the current context or open a scheduled source, then start a review from the Chat panel.

In a [notebook](/studio#inside-a-notebook), the chat reads the sources ticked in the notebook's Sources column, its own and those of any notebook you put into its context, and it can still reach the rest of your library when you ask it to. A new chat there starts in the notebook, an empty one offers **Suggest questions**, **Quiz me on it** and **Feynman Technique**, and what the chat makes (a Page, a course, a picture) is filed in the notebook. Outside a notebook, **Feynman Technique** in the icon strip's ⋯ (pin it with **Show in Sidebar**) runs the same chat on what you read, heard or watched yesterday and today.

On the Mac, any chat can take you somewhere: "open this notebook", "show me that paper" or "go to my Bioelectricity notebook" opens it in the window, as clicking it would. Chat says it opened, made or changed something only when it actually did.

You never have to wait for a reply to finish before saying the next thing. A message sent while the tutor is still writing waits in a queue above the composer, one line each, and goes the moment the reply ends, as in Codex. Each queued message has **Send now** (the ↑: the reply stops where it is, keeping what it said, and this message is asked next), **Edit** (back into the composer) and **Delete**. **Stop** ends the reply and returns anything waiting to the composer. In Web Studio a queued message waits under the reply, with a × that hands it back.

## The composer and the transcript

The composer is a card at the foot of the chat, where it stays from the first message on. The notebook the chat works in and what it has read in (**N in context**) sit on a grey tray behind the card's top edge: click the notebook to open it, or the count to see and remove what is in context. The tray also names each source open beside the chat, such as a paper in the Reader or a video playing, because the chat sees what you have open: "this paper" or "what did he just say?" means it. In Web Studio that is the source in the Reader beside the chat, in the library or in a notebook; a window too narrow for both shows one at a time, so nothing is beside the chat there. To ask about something else, point at its name and click its **×**. The chat then leaves it out for as long as it stays open; close it and open it again, or start a new chat, and the chat sees it again. **+** on the left adds files, sources or Deep Research; the dark circle on the right sends, as Return does, and while a reply is being written it becomes Stop, a square. An empty chat shows its notebook or a greeting in the middle, with a few starting points just above the composer.

Your messages sit on the right in a grey pill; point at one for **Copy**. When a reply used tools or thought first, a line above it says how long it worked ("Worked for 2m 17s"); click it to see the steps. Web Studio's chat looks the same.

### What the composer does, as in Codex

- **`@`** opens a list of your library above the field, in tabs **All · Sources · Pages · Chats · Notebooks**; type to search. A source joins the chat's context, a notebook brings its sources, a Page or Site is attached for the chat to read, and a chat waits above the field as a chip whose transcript goes with your next message (its × leaves it out). The connected plugins (`@slack`, `@linear`, `@github`, `@notion`) are listed under All. `/source`, `/page`, `/site` and `/notebook` still work. Web Studio's `@` finds sources, Pages, chats and notebooks.
- **Thread commands:** `/rename` (with a title, or bare to edit the title), `/pin`, `/hide` (hides the chat from Chats, Codex's archive), `/fork` (the chat so far in a new one), `/side` (a side chat about the whole chat) and `/reasoning` (the model's effort).
- **The model chip** lists **Recent models** at the top, each with the effort you used it with; **⌃⇧M** opens it.
- **A long paste** (more than about 24 lines or 4,000 characters) becomes a **Pasted text** chip above the field rather than a wall in it; click it to put the text back in the field (**Show in text field**), or × to leave it out. It is sent after your words.
- **Drafts are kept per chat**, also across a quit: what you half typed is there when you come back. **↑** in an empty composer brings back the last message you sent, to edit and send again.

### What you can do with the newest turn

- **Try Again** on the newest reply's **⋯** asks your message again and replaces the reply; **Try Again With** asks it on another model, and the chat stays on that model. Web Studio has **Try again** in the newest reply's footer.
- **Edit** (the pencil under your newest message, or **Edit Message** in its context menu) puts your words back in the composer under an **Editing message** line; sending replaces the message and the reply after it, and **Cancel** gives the composer back what it held. A message with pictures, a Reader passage, a side-question mark or a guess is not offered Edit.
- Both are offered in chats, not in reviews, and not while a reply is being written.

### Finding your way in a long chat

- **⌘F** with the chat focused (or just clicked) opens **Find in chat** over the transcript. Return or **⌘G** goes to the next turn that holds your words, ⇧Return or **⌘⇧G** to the previous; the turn scrolls into the middle and is marked, and the bar says where you are ("2 of 7"). Escape closes it. A Reader beside the chat keeps ⌘F when it has the focus.
- Scrolled up from the newest turn, a round **↓** at the foot of the transcript takes you back down (macOS 15 and later).

## Pictures from a source

Ask to see a figure — "show me Figure 3-4", "is there a picture of the fermentation pathway?" — and Chat shows the original picture from the book chapter, paper, or article in the transcript. Right-click it for **Copy Image** and **Open Beside**, or drag it straight into another app. Click the picture to see it full-window; **Open Beside** puts it big in a pane next to the chat instead, so the question you are answering stays on the left. In a notebook that pane is the one beside the chat, and its **×** closes it; in a chat with no notebook it opens in a small window you can place anywhere. Click inside it to zoom in and click again to fit it, or pinch. Opening another picture beside replaces the one shown. The same picture appears when the chat is opened on another Mac or in the Web Library, because the transcript names the picture by source and position rather than by a file on one machine.

Slides work the same way for videos and recordings. Ask "show me the slide that shows X" and Chat matches the request against what was said while each slide was on screen — the words need not have been said together — then shows that frame. A video or recording whose slides have not been captured yet is captured by the request itself — the same pass as the reader's **⋯ › Video › Show Slides**, reading a meeting's recording from Google Drive when it lives there — and the deck then appears in the reader too. You can also ask for the capture on its own ("extract the slides from this talk"): Chat runs it as a *Captured slides* step and lists every slide with the stretch of the talk it was on screen, ready to show. Slide frames exist only on the Mac that captured them, so Web Studio marks such a picture unavailable rather than drawing it.

When Chat quizzes you over slides or figures, it shows one picture at a time: the one the question is about, right above it. The next picture comes with the next question, after you answer.

## Interactive visualizations

On the Mac, a reply can draw a picture that runs: a curve with a slider for its rate, a process you step through, a mechanism whose parts you switch on and off. Chat draws one when it explains the point better than words, or when you ask ("show me this as an interactive chart"). It runs in the reply, in a frame that cannot reach your library or the internet. It is the same block a Page's **Visualize** row writes, so its Markdown runs in a Page too. The Web Library and the iPhone show a line in its place.

## Running code

On the Mac, Chat can run Python when an answer is a matter of computing: a statistic, a unit conversion, a simulation, a table reshaped, a chart, a molecule drawn with RDKit. Ask in plain words ("plot guanine next to 8-oxo-guanine", "what is the half-life if it falls from 80 to 20 in 6 hours?"). Each run is a step in the reply's "Worked for" line; open it to read the code and what it printed, and a picture the script saved appears in the reply, where you can copy or drag it out like any other picture.

- **A real Python.** The first run sets up an environment with numpy, pandas, matplotlib, scipy and sympy, which takes a minute and needs a network; it is kept for every chat after. Chat can name another package from PyPI (rdkit, biopython, scikit-learn, seaborn) and it is installed first. Only binary wheels are installed, so a package that ships none for your Mac cannot be used. ForeverLM uses [uv](https://docs.astral.sh/uv/) when it is installed, which also fetches a suitable Python; otherwise it needs Python 3.10 or newer.
- **A folder for each chat.** A script runs in a working folder that lasts as long as the chat, so a file it writes is there on the next run; variables are not. Files other than pictures are listed in the step, with the folder named.
- **Kept apart from your Mac.** A script runs in a macOS sandbox: it can write only to its own folder, has no network, and cannot read your Documents, Desktop, Downloads, iCloud Drive, ForeverLM's library, mail, keys or other app data. It starts with a bare environment, so it sees none of your accounts' settings. A script stops after 60 seconds unless Chat asks for longer (five minutes at most), and **Stop** ends it at once. A Mac without the system's sandbox tool runs no code.
- **Mac only.** The iPhone and Web Studio have no code tool.

## Going through a source in the Reader

On the Mac, Chat shows you what it means in the source itself. Ask it to explain a paper's key points or walk you through its figures, and it opens the paper in the Reader beside the chat, whether the paper is attached to the chat or one it just found in your library. It then outlines the figure, panel or passage its reply is about. An article or a book chapter shown as text is scrolled to the passage, which flashes. Chat takes one place a reply and offers the next, so the page beside the chat is the one being explained. Other places a reply names are citations, and clicking one takes the Reader there. A figure is outlined as soon as Chat finds it, before it has read the picture. If that reading fails, the outline stays and Chat tells you it could not read the figure. A chat in a window of its own has no Reader beside it, so it shows the figure in the reply instead. The Web Library's chat does the same in the Reader beside it, in a notebook or in your library: it opens the source and marks the passage it is explaining, or opens the PDF at the page a figure is on, though it cannot outline the figure on the page. A citation that quotes a passage opens the Reader there and marks it too. In a window too narrow to show the Reader beside the chat, the chat leaves the Reader closed.

## Pictures you drop in

Drop a picture onto the chat — a screenshot from Finder, an image dragged out of a browser, a photo — or paste one into the composer with ⌘V, and it waits as a thumbnail above the text box until you send. Send it with a question, or on its own; "what is this?" is implied. The picture goes to the model with your message, so you can ask about a figure from a paper you have not imported, a slide from a talk, or a diagram you drew. Drop several at once to compare them.

Sent pictures stay in the transcript above your message. Hover one for its name, right-click to copy it, or drag it out into another app. A model that reads text only refuses the message before anything is sent and says so, so you can pick a model that reads images from the model menu and retry; the model menu does not hide text-only models. Pictures live on the Mac that attached them: a chat opened on another Mac or in Web Studio shows "not on this device" in the picture's place, and the words you typed with it.

Pictures are attached to the message, not added to your library. Dropping a PDF, an ebook, or a text file still imports it as a source.

## Selecting words in a reply

Select words in a reply and a bar of three actions appears over the selection, the way the Reader answers a selection there; the reply's right-click menu offers the same three.

**Add to chat** drops the passage into the composer as a quote, with the cursor on the line beneath it, so you type the follow-up question under the words it is about. A draft you had already started keeps its words, and the quote follows them. Each **Add to chat** is its own annotation: the composer shows them as one **annotations** chip ("2 annotations") above the field. Click it to read the passages, edit or delete one; its x drops them all. Your sent message shows the quoted passage as a quote above your question, and the tutor reads it as the passage you meant.

**More details** asks the tutor to expand those words, here, under the reply — the same lane as the footer's More details, about the passage rather than the whole reply.

**Ask in side chat** opens a small chat in a popover hanging off the words. Type a question and the tutor answers it there, reading the passage, the reply it came from and the conversation before it; follow up as often as you like. Nothing is sent to the chat underneath, nothing is saved, and no new chat is started: close the popover and the chat is exactly as you left it. When a question outgrows a popover, the arrow in its corner moves the exchange to a new chat beside this one, with this chat's sources loaded, where nothing is held back; pressed before anything was asked, it opens that chat with the passage as its context. In a review the side chat keeps the open question's answer to itself, as a side question does. The bar over a selection in the Reader has the same **Side chat**, which answers from the source you are reading. A side chat about the whole chat, with nothing selected, opens from `/side` or **Open Side Chat** on the newest reply's **⋯**: it reads the conversation and the chat's sources, and its arrow branches the chat when nothing has been asked yet. On the Mac only.

## Side questions and More details

Two icons in the footer of every finished reply ask something about that reply without moving the conversation on.

**Side question** (the turn arrow) arms the composer for an aside about that reply: a **Side question** token appears at the head of the field, naming the reply when it is not the newest, and the next message goes to the tutor as an aside. In a review the tutor answers it without grading it, asks nothing new, and keeps the open question's answer to itself; in an ordinary chat it simply answers beside the conversation. The aside, its reply and any follow-ups fold into one lane under the reply they are about, and the lane folds to its heading once you have moved on. Under the newest lane, **Follow up** asks more in the same lane and **New chat** takes the aside and its replies to a chat of their own, where nothing is held back; while a quiz question is open, **Answer it** takes you back to it. The token's ×, Escape, or Backspace at the start of the draft take it off; ⌥Return sends a side question without it. On the Mac only.

**More details** (the magnifier over text) asks the tutor to expand that reply: the mechanism behind it, a worked example or two, the caveats, and where in your sources to read on. The expansion appears as a collapsible lane headed **More details** directly under the reply, open while the tutor writes and folded to one line once you have moved on; a click reopens it, and so does pressing More details on that reply again. It never asks a new review question, grades nothing, and gives nothing away that an open quiz question is asking. On the Mac only.

## Citing a moment

When Chat cites a video, podcast, or recording, the citation can carry the moment the passage was spoken. The marker in the reply shows it as `[2 · 12:34]`, and the source footer lists each cited moment under its source as a chip. Clicking either seeks the YouTube or recording player to that moment; a transcript without a player scrolls to the segment spoken then. Web Studio shows the same markers and chips.

## Asking about a moment of a video

Open a YouTube video in the Reader and choose **⋯ › Video › Chat About This Video**, or open a new chat beside it. When you start typing a question, the video pauses, and your question goes with the moment it stopped at: the time, what was said in the minute and a half before, and a picture of what is on screen. So "what does he mean by this?" or "what is this equation?" is answered about the slide in front of you, without typing the time. Above your question the chat shows that moment — the frame and the time — and clicking it plays the video from there, also when you reopen the chat later. In a chat about something else, a video playing beside it is noted as open but its frame is not sent. The **×** on the video's name over the composer leaves it out altogether: the chat is not told of it, and typing no longer pauses it. In Web Studio a question goes with the time the video stood at and whether it was playing, but the video does not pause, and neither what was said nor a picture goes with it.

## Reading modes

In Web Studio, choose a reading mode from the **+** at the left of the composer, where the mode then shows as a token beside the **+**:

- **Shallow Read** builds a quick, selective grasp of the source and clearly distinguishes that pass from a complete reading.
- **Deep Read** works through the source carefully, checks understanding, and follows important ideas into more detail.

The Mac app's composer offers only Chat and Deep Research.

## Text size

On the Mac, a trackpad pinch over a chat makes that chat's text larger or smaller. Only the chat changes: the sources column, a reader open beside it and the rest of the window keep their size, and a pinch over a reader zooms the document instead. The chat's size is remembered across launches.

⌘= and ⌘- zoom the whole app, and the chat follows along on top of whatever a pinch gave it. ⌘0 (View → Reset Zoom) returns both the app and the chat to the default.

The Library zooms by itself the same way, and not remembered across launches: pinch over it, or click in it and press ⌘=, ⌘- or ⌘0, and only the Library changes size; the sidebar and the other panes keep theirs. While a reader has the keyboard, the keys zoom the reader as before.

## Reviews

ForeverLM's review flow asks you to explain ideas in your own words. The tutor probes gaps, asks follow-up questions, and records the exchange as a review session.

### The review plan

When you ask a chat to quiz you on a source, the tutor sets out a plan: the topics to cover and the points under each. On the Mac the plan sits on the composer's tray as **Topic 2 of 7**. Click it to see every topic with its points ticked off as you answer, the question waiting for your answer, and what was set aside for later. Click a topic to go there.

As you answer, the tutor writes each point's answer under it: the step of the argument settled in a sentence or three, from what you said and what it corrected, with a picture from the chat when one shows it. A point with an answer has an arrow; click it to open the answer, or choose **Show All Answers** from the plan's **⋯** menu to read the whole argument top to bottom. Click a picture to see it full-window.

When you leave the plan to ask about something else, the plan shows the path you took ("Plan › 1 What mitochondria do › Lane on apoptosis"). **Back to plan** drops the side questions and asks the open question again. To take the plan out of the chat, choose **Clear Plan** from the plan's **⋯** menu: the tray stops showing it and the tutor no longer works from it, until you ask for a new one. A plan the tutor replaced or you cleared is listed under **Earlier plans**. The plan is saved with the chat, so it is there again when you reopen it. On the iPhone and in Web Studio it shows as a **Review plan** line in the transcript for now.

A notebook's **Feynman Technique** turns this around: you say what you know about the notebook first, from memory (press its chip, or just ask for it in the notebook's chat), and the tutor asks, one question at a time at the biggest gap, then fills in what is missing once you have tried, in pictures and one short question at a time: a figure from your sources when one fits, and a plain diagram it draws for the idea when none does, with no plan and no explaining before that (see [Inside a notebook](/studio#inside-a-notebook)). It is kept as a review too, and a reopened one goes on asking. On the iPhone it reads like any review, and continues on your Mac.

Completed in-app reviews are linked to the source IDs they covered. That link is what updates a source's Reviewed status, and a review that grades a source planned in Schedule marks it done.

## Memory review

On the Mac, today's memory review is your cards: the **Memory** row in the rail opens [Memory](/studio#memory), and **Start Review** there deals them. The review by chat described here is what each day's review was before cards, and what the iPhone's voice still speaks. The iPhone's Memory card opens its card review too; a day's chat you have already answered in can be continued from that review's **⋯** › **Continue Today's Review Chat**. There is one per local day, titled by its full date (for example **3 September 2026**) and shown with a brain glyph; on the Mac, **Your reviews** in Memory opens an earlier day's chat from its square.

The review is planned over what you took in yesterday, what is due again, and one bridge from another stretch of time, and it is organized by **topic**, not by source: the planner groups the day's ideas into a handful of topics about the same thing, whichever sources or chats carried them, sized to your daily minutes (four topics and a connection at fifteen). The tutor opens with one sentence naming today's topics, then asks the first topic's question: a free recall of what you now understand about that subject, answerable from anything you read, heard, watched or talked through. Before replying, the tutor privately grades every idea the topic cues, crediting each one whichever source it came from, and a source's next review date follows how much of its ideas came back unaided the first time they were asked that day. A chat's ideas join topics like any source's; no question asks what a conversation was about. On a day with nothing due the review still opens, on the material that has gone longest without being discussed, and the tutor says so.

Each topic is a card. Its head names the topic and its kind (New, Due again, Weak spot, or the day's one Connection across two topics from different times); the question is set large, the sources it draws on sit under it as small faces that open in the Reader, and the answer field is on the card, with **I don't remember** for an honest miss that costs no typing. After the grade the card shows a ledger: one row per idea, filled for what came back, half for what came back in part, and a veiled row naming only the source for what did not, so a missed idea is never read out to you. Under the ledger, **Go deeper** (⌘D) stays with the topic and probes what did not come back, one idea at a time; an idea missed twice is re-taught from its source and comes back tomorrow. Once everything came back, Go deeper goes past recall instead: one question on one of the topic's ideas asking for the principle behind it (with no names in it), where else it applies, what would prove it wrong, or what it is like, set beside an idea from a source in another of your notebooks, a different kind each time. How you answer says how deep your understanding goes; it never marks the idea as forgotten. **Next topic** (⌘↩) moves on. Right-click an idea's row to open its source in the Reader or to say it is **Not something I read**, which takes that source out of the day.

A session bar above the card replaces the old strip of source chips: a segment per topic (a finished one filled, the current one accented; click a finished one to read its card again, a waiting one to take it next) and, while the card holds the answer field, the model picker. The ⋯ menu's **Show as Conversation** draws the same chat underneath the cards, with the composer back. A review that was planned before topics existed keeps its per-source cards, strip and chips. Each source is reviewed at a depth of quick, standard or deep, as before, and review depth syncs with the source. A memory chat reopens onto the same plan after a relaunch.

## Copying a chat's link

A chat row's **Copy Link** puts the chat's address, `foreverlm://chat/<id>`, on
the clipboard. Opening the link brings the chat back up in the app, and a Page
renders it as a link to the chat. It is also how a chat is handed to an
assistant working through the [ForeverLM plugin](/mcp-tools): paste it to Claude
or Codex and `get_review_session_transcript` reads the chat by the link — no id
to look up — and every other tool that takes a `session_id` accepts the link in
its place. A chat that is still going returns its turns so far, so the assistant
can follow a conversation you are having in the app while it works.

## Sharing a chat with a team

A chat row's **Share Transcript with Team ▸** menu copies the conversation into a
[team](/teams) as a read-only transcript. The team's copy carries the questions,
your answers and the tutor's replies, the sources the chat covered where the
team also holds them, and the chat's title and summary. Everything that is about
you rather than the conversation is stripped: scores, thumbs, which ideas you
recalled, the verdict on each question, the steers you gave the tutor, and the
reader passages you were looking at when you asked. Sources the team does not
hold are dropped from the copy rather than pointing into your library. Your own
chat stays private and live, and a chat shared twice updates the same
transcript.

A transcript you shared by hand stays as it was when you shared it. A notebook
you share into a team you own moves there with its chats, except your reviews,
quizzes and memory reviews, which stay in your own library. See [What follows a
shared notebook](/teams#what-follows-a-shared-notebook).

## Review history

The rail lists each notebook's chats under it and the rest under **Chats**, and the sidebar beside a chat lists every chat, in a notebook or in none. In-app reviews are there, and so are external Claude, ChatGPT, Gemini, Grok, or Edison Scientific reviews saved into ForeverLM.

Stored sessions can include:

- The source IDs reviewed
- The transcript or recorded exchanges
- The completion status
- The score and summary when available
- Start and end timestamps

## Web search

Ordinary Chat can search the web when the question calls for it. Every model
runs through OpenRouter. On models with a native search engine (Anthropic's,
OpenAI's, xAI's and Perplexity's), the model searches as part of its reply and
nothing is charged until it actually does; on models without one, a search bills
one Exa request, so the model only asks for one with a focused query. Gemini
stays off the web, because Google bills search against an account-wide allowance
that cannot be priced per request.

When a chat cites or discusses a paper your library does not hold, it says so
and offers to add it. Ask ("add that study") and it finds the DOI or publisher
page itself and imports the paper through the normal [paper pipeline](/papers),
so you never have to paste a link. If the publisher blocks the PDF, the paper is
still added, marked paywalled.

## Deep Research

Choose **Deep Research** from the **+** at the left of the composer, on
the Mac or in Web Studio, to make the chat a research agent. A **Deep
research** token then heads the field (in Web Studio it sits beside the
**+**) for as long as the chat researches; its ×, Escape, or Backspace at
the start of the draft turn it off. It works the way a dedicated research product does:

1. It opens with a short plan: the question as it understood it, the
   sub-questions or entities it will cover, and the kinds of sources it will
   look for.
2. It searches the web several times per sub-question and reads the pages that
   matter in full, so claims rest on the page rather than on a search snippet.
   Each search shows as a **Searched the web** row listing the pages found, and
   each page read as a **Read web page** row. The web stays available through
   every step of the reply, up to forty steps of twelve searches each.
3. It keeps working notes in a Page titled "Research notes: …" as it goes, then
   writes the complete report into a Page titled "Research: …" (a summary, a
   section per entity or sub-question, documented fact separated from inference
   and speculation, open questions, and sources, every claim linked to its page).
4. The chat reply gives the key findings and names the report Page, which you
   open from the Space's **Pages**.

Every web page the reply searched or read is listed under it as **Web sources**,
folded to one line with a count until you click it open.
On the Mac each row shows the page's title and site: click the title to read the
page beside Chat without importing it, or click **Add** to keep it in your library.
Add runs the same import as the Reader's "Add to Library" button, so a page
already in your library reads **Added** and a new one is deduplicated the same
way. Nothing is added to your library unless you click Add.

A long research question takes several minutes and many model calls; the Stop
button ends the run at any point, and the notes Page holds whatever was found so
far.

## Voice input

The Chat panel supports voice dictation for review answers. On the Mac, audio is recorded temporarily and transcribed after you stop by the speech-to-text model in **Settings → Voice → Speech to text**. The web library's composer does the same on that model: it records for up to five minutes, sends the recording once you stop, and puts the words in the composer. On the iPhone, Apple's on-device speech recognition hears you instead. Raw voice audio is not persisted.

## API keys and errors

In-app Chat uses the chat model you choose in **Settings → Chat**, run through OpenRouter on your own key — see [AI Providers & Models](/ai-providers). OpenRouter bills each request at its cost. If the selected model cannot complete the request, ForeverLM should surface the error instead of silently switching to heuristic grading or fallback feedback.

External AI assistants are still supported. Drag and drop remains the quickest no-setup workflow, and MCP remains the best option when you want Claude, ChatGPT, Gemini, Grok, or Edison Scientific to search and manage the full library.
