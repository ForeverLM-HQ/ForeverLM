---
layout: doc
title: Text to Speech
---

# Text to Speech

Text to Speech lets you listen to articles and other text sources in ForeverLM. It is designed for the moments when reading is awkward but listening works: walks, chores, commutes, or reviewing a source before a review session.

## Start listening

Open a source in the Reader and choose **Listen** from the Reader's **⋯** menu, or right-click inside the Reader and choose **Text to Speech**. While the audio is prepared or plays, its control sits on the Reader's toolbar. ForeverLM extracts the readable text, prepares audio, and shows playback controls at the bottom of the reader. Playback is not tied to the reader: switch to another source, close the reader or move to Chat and the audio keeps going, and a Now Playing bar appears at the bottom of the window with the same controls, so there is always a visible way to pause or stop. Click its title to return to the source, and the bar folds back into the reader. To prepare the complete audio without starting playback, right-click the source in Studio and choose **Generate Audio**.

While a source's audio is being generated, its row in the Studio sidebar shows a spinner where the speaker badge appears once the audio is ready. While cloud audio is being generated, the progress status names the exact model handling that generation alongside its completion percentage. It remains tied to the in-flight generation even if the model selected in Settings changes before the remaining chunks finish. Web Studio shows the same model and percentage while it generates each chunk.

Sources that already carry their own audio — podcast episodes, YouTube videos, and meeting sessions whose recording plays in the reader — do not offer Text to Speech. Play the original recording instead; generating speech from their transcripts would only duplicate it. Meeting sessions without a playable recording (for example Read AI imports, which are transcript-only) keep Text to Speech.

Playback controls include:

- Pause and resume
- Back 15 seconds
- Forward 15 seconds
- Speed selection from 0.75x to 2x
- Stop

## Text-to-speech models

Choose the Text to Speech model in **Settings** -> **Voice** -> **Text to speech**
on the Mac, or **Settings** -> **Text to Speech** on the iPhone. The list is
every speech model OpenRouter serves
([openrouter.ai/models?output_modalities=speech](https://openrouter.ai/models?output_modalities=speech)),
read live, so a model OpenRouter adds appears without an app update. The Mac
groups the models by maker, with each model's voices and OpenRouter's price
under it. While the list is being read the pane says so, and if OpenRouter
cannot be reached it says why and offers **Try Again**, showing the last list
it read.

Every model, Grok and Gemini included, is requested from OpenRouter. Cloud
voices run on your own OpenRouter key, which needs a ForeverLM plan; OpenRouter
bills them at its cost. The one exception is Orpheus 3B, which OpenRouter still
lists but ForeverLM leaves out: it resets its intonation every ~180 characters,
so it cannot read anything long.

A model's voices are the ones OpenRouter lists for it. Where ForeverLM knows a
voice, it has a name, an accent flag, and the languages it reads. Other voices
are shown by their id. Fish Audio's models list no voices on OpenRouter, so they
use the voice OpenRouter's own sample for them uses. Seed Audio lists none at
all and speaks in its provider's default voice.
Voice pickers prefix provider-documented regional accents with their country
flag and use `🇺🇳` for multilingual voices, and for voices whose languages are
not published, instead of a generic globe glyph.
The native apps prepare the short “Mitochondria are much more than just the
powerhouse of the cell” sample in the background for the voices ForeverLM
curates (the first voice of a model it does not curate). Every voice of the
selected model gets a separate high-priority, bounded warm-up, so its preview
buttons play from a durable device cache once preparation completes. Any other
voice's sample is made when you tap it, since each sample is a billed request.
Thumbs-up and thumbs-down reactions are saved per model and voice and follow the
account across the Mac, iPhone, and Web Studio.

On-device macOS speech and a local Qwen3-TTS server remain free alternatives
that do not send narration text to a cloud speech provider. See
[AI Providers & Models](/ai-providers) for the complete model list.

## Sources that are not in English

Every model ForeverLM curates declares which languages it narrates, and
ForeverLM checks a source against that declaration before it generates anything.
OpenRouter publishes no language list, so a model or voice ForeverLM does not
curate has its languages marked as not published. That is never read as English.
Such a model is never picked as a replacement for a language, and a source is
never moved off it; its card says the languages are not published. The check
is on-device and deterministic: it samples several windows spread across the
source — not just the opening, which is often an English title or abstract — and
classifies them. Short, mixed, or ambiguous text is left alone rather than
guessed at.

The default, Gemini 3.1 Flash TTS, is the broadest entry in the catalog: Google
publishes more than 70 languages for it, so most non-English sources are already
covered by the default selection. Most other entries are English-only, and a few
name a short list — MAI Voice 2 ships one voice each for English, Spanish,
French, and German.

When the source is in a language your selection does not narrate, ForeverLM
moves it rather than generating anyway. A sibling voice of the same model wins
first (German text goes to MAI's German voice, at the same price and latency),
then the default model, then a model with a voice built for that language. The
reader tells you which voice it used and which one it replaced. This matters
because a model handed a language it does not speak still returns audio and
still bills for it — the words are simply read with the wrong pronunciation.

Web Studio does not run this check; it narrates with the model and voice you
selected.

## Pricing before generation

Each model's card shows OpenRouter's price in the unit OpenRouter bills that model by: per million characters for most, per million UTF-8 bytes for Fish Audio, per million text and audio tokens for Gemini, per minute of audio for Seed Audio. `:free` models show as free. The prices come from OpenRouter, for the host it routes each model to, and none is written into the app. A model OpenRouter has not priced shows **Price unknown**, never free. Before an uncached source is generated manually, ForeverLM shows its narration length, how long the finished audio runs, and its cost. That is a total for a model billed by the character. For a model billed another way it is the model's own price ("priced at $1 / $20 per 1M tokens"), because a total would have to be guessed. A selected model is never silently replaced by a second paid one. This confirmation is on by default. Selecting **Don't ask again for this model** suppresses it only for that model, across all of the model's voices; choosing another model asks again. It has no Settings pane: ask the chat to turn confirmation back on for the selected model (`read_aloud.confirm_cost`).

The estimate uses OpenRouter's price as last read. The exact managed charge appears in **Settings** -> **Billing** -> **AI activity** after generation; retries can add cost. Replaying cached audio does not generate or charge for new speech.

## Automatic audio

Text to Speech can prepare audio on its own, chosen per kind of source: **Articles**, **Papers**, **Books**, **Courses**, and **Explainers**, in any combination. Every kind starts off. Podcasts, videos, and meetings with a recording have none: they arrive as audio already, so ForeverLM never narrates their transcripts. A book's switch covers its chapters, and a course's covers its documents.

**Explainers** is its own kind: "always generate audio for explainers". An explainer is saved as an article-typed source, but it never falls under Articles, so narrating every explainer does not mean narrating every article. With it on, an explainer's audio starts the moment the script is written — from the Reader's **Explain** button, from the source's menu, or from an assistant's `generate_explainer` — with the selected voice and no cost question: asking for it once is the consent. An explainer that arrives from another device is narrated the same way, and rewriting an explainer narrates the new script. Over MCP it is `kind: "explainer"` in `set_automatic_audio_settings`.

There is no Settings pane for it. You set it by asking — in the app's chat, or from Claude or ChatGPT connected over MCP — for example "always generate audio for articles from Martin Picard", "narrate every new paper about mitochondria", or "stop generating audio for books". The assistant calls `set_automatic_audio_settings`, and `get_automatic_audio_settings` tells it what is on, what each kind has waiting, and what that would cost.

Each kind takes an optional natural-language rule. A rule is judged from each source's title, author, journal, year, collection, URL, and short description by the **Automatic Audio Filtering** background task. It is tried against the sources already waiting before it is saved, and the reply lists what matched with the combined characters and price; an invalid or failed AI answer never saves the rule, so it never broadens the queue. An empty rule means every source of that kind.

Switching a kind on starts every matching source already in the library as well as later arrivals. A free voice needs no further permission. A paid voice is refused until the account consents to paid voices, and an assistant is told to put the priced total for the waiting library to you before it passes that consent. A voice with no exact catalog price never runs. The Mac and iPhone workers re-read the voice and the consent between every source, so a withdrawn consent or a changed voice stops the next item rather than the pass as a whole.

**Explainers** is the switch for "always generate audio for explainers". An explainer is saved as an article-typed source, but it has a switch of its own and never falls under Articles. With it on, an explainer's audio starts the moment the script is written — from the Reader's **Explain** button, from the source's menu, or from `generate_explainer` — with the selected voice and no cost question.

The iPhone's **Automatically continue books** setting is separate: it generates the next chapter when the current one finishes, whether or not the Books switch is on.

The switches, rules, and paid consent are all per account and sync, so a kind switched on from any chat behaves the same on the Mac and the iPhone, which do the generating. Automatic speech on a free voice costs nothing; on a consented paid voice every generated source is billed to your OpenRouter key. A non-empty semantic rule also uses the configurable background text model when it is checked or re-evaluated, so that smaller filtering call has an AI cost of its own regardless of which voice is selected.


### Listening to a book

Listening to a book chapter runs on into the next chapter when it ends, so starting chapter one commits to the whole book rather than to that chapter. Text to Speech prices it that way: the confirmation names the book and shows two lines, the chapter you started and the whole book, each with its character count, listening length, and estimated cost. Chapters whose audio is already cached are left out of the book total, since replaying them costs nothing.

Approving that price approves the book. Playback moves from chapter to chapter without asking again. Changing the Text to Speech model or voice still invalidates mismatched cached audio, but a model whose confirmation was dismissed stays dismissed when only its voice changes; choosing another unsuppressed model asks again.

The chapter line is measured from the exact narration text. The rest of the book is estimated from each chapter's stored length before its narration is prepared, so the book total is close rather than exact, and a chapter with no stored text yet is left out instead of guessed at.

Web Studio shows the same two lines when you generate audio for a book chapter there, estimating sibling chapters from their word counts. The iPhone shows the book's price in the confirmation itself, because chapter continuation there generates the next chapter in the background without a second prompt: approving one chapter is approving the book, and the alert says so.

### Generating a whole book

Right-click a book in the Studio sidebar and choose **Generate Audiobook** to narrate every chapter that does not have audio yet, in reading order, after one price confirmation for the whole book. A book whose every chapter has audio shows a filled speaker badge on its row; a dimmed speaker with a count means some chapters have it. A panel at the bottom of the sidebar follows the batch: one bar per book with the chapter being narrated, a **Stop** button while anything is still running, and the tally once it finishes, which stays until you dismiss it. Stopping keeps every finished chapter; chunks already generated are cached, so generating those chapters again costs nothing for them.

### Generating from an AI assistant

A connected assistant can do the same through MCP. Ask it to "generate audio for all my books", for one book, or for particular sources, and it calls `generate_source_audio`, which uses the voice chosen in Settings. When the run would cost money the tool answers with an estimate first — characters, listening time, price and model — and starts nothing until the assistant calls again with your explicit agreement; a free voice starts immediately. The same progress panel shows in the app, and the assistant can report progress with `get_source_audio_status` or stop the batch with `cancel_source_audio_generation`. See the [MCP Tools Reference](/mcp-tools#text-to-speech-audio).

### Equations and tables

Text to Speech never recites an equation symbol by symbol. Papers and articles run through a preparation pass before narration that states what an equation expresses when the surrounding text gives enough context and otherwise leaves it out, turns a table into a sentence about what it shows, and drops citation markers. A book or course chapter is read as it stands unless its text carries the layout that pass exists for — displayed equations, LaTeX, or table rows — in which case it gets the same pass, so a textbook chapter is narrated like a paper while a novel's chapter costs no text-model call. Inline chemistry in running prose, such as "CO2 and H2", is read as written.

## Caching

For cloud TTS providers, generated audio can be cached so replaying the same source does not regenerate every chunk. Studio can show a Text to Speech cache indicator for sources with cached audio.

If the source changes or the chosen provider, model, or voice changes, ForeverLM may need to generate fresh audio.

When cloud TTS finishes generating every chunk for a source, ForeverLM writes a synced audio manifest, source text, and chunk files to iCloud Drive. The iPhone can play that audio immediately. If a paper or article has no audio yet, asking Siri on the iPhone to play it can generate it on demand through managed AI, cache it in the same synced format, and start playback without needing the Mac.

Web Studio offers the models ForeverLM curates and requests each from OpenRouter as well, Grok and Gemini included, through ForeverLM's proxy. It keeps audio generated there in its bounded, signed-in browser cache. It resumes from completed chunks after a failed request and plays the cached audio from the Reader's **Listen** button.

## iPhone voice

### Talk

The iPhone talks with you turn by turn. Where you start it decides what it talks about and where the conversation is saved, exactly as if you had typed it:

- **Talk** in the Reader or on a source row (swipe it), or **Talk It Through** at the end of a walkthrough: a chat about that source, kept in the notebook you opened it in, if any.
- **Talk** in a notebook's Chat tab, or the waveform on its row on Home: a chat about the notebook's ticked sources, kept in the notebook. With a chat open, Talk continues that chat by voice, and so does **Continue chat with voice** in the Reader's chat.
- **Review me** in a notebook's Studio: the same notebook chat, opened with "Quiz me on these sources, one question at a time."
- **Review by Voice** in the **⋯** of the iPhone's card review: today's whole memory review, spoken.
- The waveform button on Home, and CarPlay: ForeverLM first offers a source, the audio you were last playing, else something on today's plan, else what you read or discussed most recently. "Shall I quiz you on …? Say yes, name another source, or ask for your memory review." Say yes, or a title, and it talks about that source; ask for your memory review ("my memory review", "what's due") and it holds today's review instead.

Apple's speech recognition hears you and waits for a short pause. Your chat model answers as it would in a typed chat, and Apple's speech synthesis speaks the answer. In a chat, the model is asked to keep spoken answers short and free of formatting, since they are heard rather than read. The microphone is off while ForeverLM speaks, so let it finish before you answer. The screen shows what it heard or is saying and the sources it reads, with Mute and End. Ending shows the conversation's transcript and takes you back where you started.

### Siri

Siri's ForeverLM shortcuts (**Ask ForeverLM**, **Quiz me with ForeverLM** and the rest) run a hands-free loop that controls listening and source audio:

- Start playing a source by title, position, current source, or best available default
- Pause, resume, or stop playback
- Move forward or backward in the current audio
- Change playback speed between 0.75x and 3x
- Tell you what source is currently active
- List the sources in your synced library
- Generate or reuse TTS and immediately read a paper or article aloud
- Refresh the synced library and its audio

It can also enter source chat and review:

- Start a voice review for the current source or another synced source
- Pause the current TTS audio and prepare the source text for questions
- Treat a spoken question during playback as a request to pause and answer from the current text
- Continue a source-grounded conversation once review mode is active
- End review mode and optionally return to audio playback

Typical flows:

- Ask Siri to have ForeverLM play an article.
- While listening, ask to pause so you can talk about the article. ForeverLM pauses playback, loads the synced source text, and waits for your question.
- Ask any question about the text. The source chat answers from the synced source text and speaks the response aloud.
- Continue asking follow-up questions naturally.
- Ask to go back to listening when you are done reviewing.

Talk and Siri both need Sign in with Apple. Their chats and reviews are saved through the same CloudKit records the Mac ingests.

## Good use cases

Text to Speech pairs especially well with Schedule:

- Listen to today's assigned article
- Pause to make a quick note or ask Chat a question
- Start a review after listening
- Mark the scheduled source complete after the review is linked
