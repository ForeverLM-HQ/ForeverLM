---
layout: doc
title: MCP Tools Reference
---

# MCP Tools Reference

This is the complete tool contract of the official ForeverLM remote plugin
used by ChatGPT, Claude, Gemini, and Grok: every tool the Mac app declares,
plus `import_epub` and `open_foreverlm`, which the gateway answers itself
(`open_foreverlm` is the launcher for the plugin's own ForeverLM home in
ChatGPT and Codex, not a tool for the model). See [Connect an AI Assistant](/setup-mcp) for setup. Many tools
need the learner's Mac open and connected; each section says which.

A [plugin you build yourself](/build-your-own-plugin) connects to the same
server with an ingest-only permission that allows a handful of these tools
(see [Plugins you build](#plugins-you-build)).

`notebook_id` names a notebook and `list_notebooks` lists them, so "my
Bioelectricity notebook" is the notebook of that title. The tools said project
until 2026-10-04 (`create_project`, `project_id`); the old names are gone, not
aliased.

A listing or search from a Mac that is showing only part of the library for
now carries `narrowed`, a sentence that says so without naming what is left
out: a field in a JSON answer, or the first line of a text answer. An assistant
then tells the learner it cannot see what they named from that Mac, instead of
choosing the closest match. `get_mcp_status` says which Mac that is.

## Status and sources

| Tool | Parameters | Description |
|---|---|---|
| `get_mcp_status` | none | Report connection mode and capabilities. Call this first. From the Mac, `icloud_account` says which iCloud account its library syncs with (`syncs_with_icloud`, `environment`, and `user_record_name`, the account's container-scoped CloudKit user record name, the same kind of id `list_teams` gives for members, once CloudKit has answered); ForeverLM on the web uses it to ask only a Mac on the learner's own account. `answered_by` says which Mac answered, since another Mac signed in to the same account can hold the connection: `app` and `build`, `device_id` (that Mac's ForeverLM sync id), `model`, and `computer_name`, which is left out while its answers are `narrowed`. |
| `list_sources` | none | List source metadata from the library. |
| `get_source_content` | `source_id` | Return canonical readable text for one exact source ID. |
| `inspect_paper_figure` | `source_id`, `figure_label`, `panel_label?`, `approved_spend_usd?` | See a figure of a paper as an image, rendered from the paper's own PDF on the Mac and cropped to the figure, with its caption and ForeverLM's explanation of it. `panel_label` crops to one subfigure. The first look at a figure runs the vision model. Needs the Mac open and connected. |
| `show_source_image` | `source_id`, `query?`, `page?`, `slide?`, `at?`, `crop?` | See a picture from a source as an image: a figure from a paper, chapter or article by label or caption words, a PDF page a listing named, or a slide captured from a video or recording. `at` captures the frame on screen at any time in a video (`4:25`, or seconds), and `crop` zooms in on part of a slide or frame. No filter lists the pictures; up to four matches come back as images. Needs the Mac open and connected. |
| `search_sources_semantic` | `query?`, `source_type?`, `added_from?`, `added_to?`, `limit?`, `threshold?`, `notebook_id?`, `exclude_notebook_id?`, `show?` | Search on-device source embeddings, optionally within one source type or by the local day a source was saved to the library (`added_from`, `added_to`, full `YYYY-MM-DD` days; a work's publication year belongs in `query`, never here). `query` may be left out when the type or the days name the sources. This requires an active Mac; hosted MCP reports the capability as unavailable instead of silently changing the result. |
| `search_sources_keyword` | `keywords`, `match?`, `limit?`, `snippets_per_source?`, `source_type?`, `notebook_id?`, `show?`, `source_ids?` | Find every source whose title, author, or text literally contains a word or phrase, as a case-insensitive substring, with a mention count and passages for each. This is the exhaustive sweep the ranked search is not: `uncoupler` finds a source that only says `uncouplers`. One call takes up to 30 keywords; `source_ids` limits the sweep to particular sources, such as the papers in a chat, and the answer names the keywords none of them contain. It requires an active Mac, because the full text lives there. |
| `list_shows` | `kind?` | List every podcast show and YouTube channel in the library with its episode count. Gives the exact names `filter_sources` and a search's `show` take. Needs the Mac open and connected. |
| `filter_sources` | `show?`, `author?`, `title_contains?`, `text?`, `source_type?`, `include_archived?`, `limit?` | List every source whose metadata matches: all of one show's episodes, every paper by an author, everything with a name in its title, byline or show. Case-insensitive substrings, combined with AND, never ranked or cut off by similarity. Needs the Mac open and connected. |
| `get_app_context` | — | What is open in the Mac app: the notebook each window holds, frontmost first, with its title, `notebook_id` and source count, then the sources the frontmost window's notebook reads. Call it only when the learner asks about what is open; it is never a default scope. |
| `get_sync_status` | — | iCloud sync health for this Mac: changes still waiting to upload, records CloudKit never acknowledged, quarantined conflicts, the container environment, whether iCloud is full, and how much of the learner's iCloud ForeverLM's files take. `migration` reports the library's move to the new iCloud store. Use it when items are missing or stale across devices, before concluding anything is lost. |

## Settings

Settings › Sources › **Search & AI** in the Mac app, per source family, and whether each family's tab is pinned. **Search & AI** is the knowledge boundary: a family switched off stays in the library but is left out of chat, semantic and keyword search, reviews, and every library tool above. **Tab** is whether the family's tab is pinned to the Studio tab bar; the tab bar pins it, and Settings has no switch for it. Hiding a single source is visual only and is not a setting here. Both tools need the Mac open and connected; the choice syncs to the learner's other devices.

| Tool | Parameters | Description |
|---|---|---|
| `get_source_settings` | — | Every family (`articles`, `papers`, `books`, `courses`, `meetings`, `podcasts`, `youtube`, `x`) with `include_in_search_and_ai`, `pinned` and `can_unpin`, in the learner's tab order. |
| `set_source_settings` | `family`, `include_in_search_and_ai?`, `pinned?` | Flip one family's switches. Pass one or both. Unpinning the last pinned family is refused: the tab bar keeps at least one. Returns the family's row and `changed`. |

Settings › General › **Memory review** in the Mac app. The budget, the day's new cards, background card drafting and its corner card, and the switches follow the account; the hour and the receipts are the Mac's. Both tools need the Mac open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `get_memory_review_settings` | — | `budget_minutes`, `new_cards_per_day`, `auto_draft_cards`, `draft_nudges`, `prepare_review_questions`, `prepare_daily`, `ready_by_hour`, with `automatic_drafting` (sources drafted a day, this Mac's last run and what it left waiting, the sources that failed today), and `last_preparation` saying what this Mac last did about the morning. |
| `set_memory_review_settings` | `budget_minutes?`, `new_cards_per_day?`, `auto_draft_cards?`, `draft_nudges?`, `prepare_review_questions?`, `prepare_daily?`, `ready_by_hour?` | Change one or several, through the pane's own entry points: the reminder follows its switch and the runner re-reads its clock. `new_cards_per_day` (1–100) also sets how many sources are drafted in the background each day, one for every four new cards. Returns the settings and `changed`. |

Settings › Sources › **Zoom Transcripts**, the recordings only Zoom can convert. Zoom records a meeting held on the Mac as raw `double_click_to_convert_*.zoom` files and converts them when the meeting ends; a meeting ended before that, or with Zoom quit, leaves the raw files, which ForeverLM cannot read. The Meetings tab and the Settings pane list each such recording with **Convert in Zoom** and **Ignore**, and these two tools are those rows. Zoom asks "Files from unknown sources" before converting a recording its meeting did not convert on the spot. When the learner has allowed ForeverLM under Accessibility, ForeverLM answers that dialog itself and converts waiting recordings on its own, one at a time and at most twice each, never during a meeting; without that permission it opens nothing in Zoom on its own. Both tools need the Mac open and connected, and the list and the ignore list are that Mac's.

| Tool | Parameters | Description |
|---|---|---|
| `list_unconverted_zoom_recordings` | — | Every waiting recording with `folder_path`, `title` (the series' title when one matches, else Zoom's file-safe spelling), `started_at`, `last_written_at`, `raw_bytes` and `ignored`; a recording written in the last fifteen minutes is left out because Zoom may still be converting it. `converts_automatically` says whether ForeverLM may use Accessibility and so converts by itself. |
| `resolve_unconverted_zoom_recording` | `folder_path`, `action` | `convert` opens the raw file in Zoom on the Mac, where ForeverLM answers Zoom's unknown-source dialog when it may use Accessibility (`answers_zoom`) and the learner does otherwise, and ForeverLM then files and transcribes the result; `ignore` takes the recording off the Meetings tab and never files it, for a meeting that did not happen; `unignore` lists it again. Ask before converting a recording the learner did not mention: it is visible on their screen and the transcription is billed. |

**Automatic audio** — set only from chat; the Settings window has no pane for it: the switches that narrate sources as they arrive, one per kind — `article`, `paper`, `book`, `course` and `explainer`. An explainer is stored as an article-typed source but has a switch of its own, so "always generate audio for explainers" never means every article; with it on, `generate_explainer` and the Mac's Explain button start an explainer's audio with the selected voice and no cost quote. Each kind takes an optional natural-language rule, and automation runs only on a voice it may spend on: a free OpenRouter voice always, a priced one only after the paid-voice consent, an unpriced voice or another provider never. Both tools need the Mac open and connected; the switches, rules and consent sync to the learner's other devices.

| Tool | Parameters | Description |
|---|---|---|
| `get_automatic_audio_settings` | — | Every kind with `enabled`, `filter`, `sources_without_audio` and, when the voice may run, the estimated characters and price; the selected `voice` and its rate; `automation_available` with an `unavailable_reason` when it is not; `allow_paid_voices`; and, for a priced voice, the `paid_consent_quote` that consenting would start. |
| `set_automatic_audio_settings` | `kind?`, `enabled?`, `filter?`, `allow_paid_voices?` | "Always generate audio for articles from Martin Picard" is `kind: "article"`, `filter`, `enabled: true` in one call. `kind` + `enabled` arms or retires one switch — refused while the voice cannot run; `kind` + `filter` saves the rule, evaluated over the waiting sources first and kept only on success, an empty string clearing it; `allow_paid_voices` is the account's consent, a spending decision to put to the learner first, and `false` stops a paid run. Returns the settings with `changed`. |

Settings › AI Usage › **API keys**: the learner's own OpenRouter key. It is how ForeverLM's AI is paid for: with one stored, OpenRouter bills the learner directly, at its cost, for everything ForeverLM sends through it, and ForeverLM adds nothing. The key covers text models (chat, reviews, background tasks) plus every voice, speech-to-text, image and video model OpenRouter serves, and the reader names that scope. While the key is stored, an AI balance left from before balance was retired pays for nothing (`balance_still_pays_for`). The key lives in the Mac's iCloud Keychain, so both tools need the Mac open and connected, and neither ever returns the key.

| Tool | Parameters | Description |
|---|---|---|
| `get_own_router_key` | — | `configured`, the `router` (`openrouter`) and `key_suffix` (last four characters) when one is stored, what text is billed to, and where to get a key. |
| `set_own_router_key` | `router`, `key?`, `clear?` | Store or replace the key for `router` (`openrouter`), or remove it with `clear: true`. Returns the same payload as the reader plus `changed`. Ask before calling it with a key the learner did not just hand you. |

Settings › **Chat** (the Default Model), Settings › **Background** (the Text
and Multimodal models every background task runs on, a task's own model, and free models),
Setup's Meetings answer, and the AI usage ledger behind
Settings › AI Usage › **Activity**: what each feature runs on, what it cost, and
the catalogue prices to compare against. The report never invents a number: a call the ledger could not price is counted in
`unpriced_calls` and left out of every total, and a model the pricing table does not
know says `price_known: false`. The `ai-cost-review` skill in the plugin walks these
three from report to approved change. These need an active Mac:

| Tool | Parameters | Description |
|---|---|---|
| `get_ai_usage_report` | `days?`, `from?`, `to?` | Spend for the period (default the last 30 days; or local `YYYY-MM-DD` bounds, `to` inclusive): `totals`, `by_task` with the models each task ran, `per_call` averages (tokens in and out, cache reads, cost per priced call) and the task's `current_route` (provider, model, which Background model or the Default Model it follows, its catalogue price), `by_model` with each model's price row, and `by_day`. |
| `get_ai_task_settings` | — | `default_model`, `background_text`, `background_multimodal`, every background task with the model it runs on and which it `follows` (`background_text`, `background_multimodal`, or `task_model` when it has a model of its own; a meeting task says `kept_off_free_model` while it runs on a paid model because its Background model is free, and `waiting_for_paid_model` when it has none to run on), `meetings_may_use_free`, and the `catalogue` grouped by maker with each model's price per million input, output, cached-input and cache-write tokens, `supports_vision`, `supported_efforts`, `route_can_carry_speed` and `selectable`, and `free_models`: OpenRouter's free models that can run text work (`text`) and work that reads images (`reads_images`), best first, with `free_model_blocker` saying why none can run when that is so. `accepts` lists exactly what the setter takes. |
| `set_ai_task_settings` | `target`, `provider?`, `model?`, `meetings_may_use_free?`, `hide_training_models?`, `host_for?`, `host?`, `host_fallback?`, `host_region?`, `backups_for?`, `backups?`, `task_id?` | Change one setting as the pane's own control does: `default_model`, `background_text` or `background_multimodal` with a catalogue `provider` and `model` ; `task_model` with `task_id` and a catalogue `provider` and `model` gives one background task a model of its own (a task that reads images takes only a model that does), and with neither sends it back to following; `task`, `effort`, `speed` and `reset` are refused; `docs` with a catalogue `provider` and `model` sets the model Edit with AI in a Page runs on, as the ForeverLM logo on its panel does, and `docs` with neither sends Pages back to the Default Model (a chat's own model pick never reaches Pages); `meetings` with `meetings_may_use_free`, Setup's Meetings answer: false keeps meeting tasks on a paid model while their Background model is free, true lets them use it; `data_privacy` with `hide_training_models` to flip Settings › Data & Privacy's "Don't show models that train on my data", which hides every model the catalogue marks `trains_on_inputs`; a free model that starts costing money, or stops being offered, is moved off every setting on its own, onto another free model that can do the same work (the Free Models Router first), and the learner is notified. `backups` with `backups_for` (`chat`, `background_text` or `background_multimodal`) and `backups`, the whole ordered list of at most ten backup models the setting's work moves to when its model is busy, fails or sends back nothing usable (`[]` removes them); every background task uses the backups of the Background model it runs on, and the chat's serve only a scheduled task's runs, never a chat the learner types in. A free model from `free_models` is taken for `background_text` or `background_multimodal` even before the catalogue lists it; it moves only that setting. Refuses any other model the catalogue does not list, a free model while `free_model_blocker` is set, a retired model, a hidden training model, a text-only model where images are read. Returns the resulting settings and `changed`. Ask before calling it. |

**Every other Settings control.** Anything the Settings window can change, chat can change too, through the same setter the pane calls. So can every setting that has no pane, which `get_app_settings` labels "(no pane)": the meeting-icon switches, the text-to-speech cost prompt and the like. The catalog tools cover the plain switches, pickers and sliders (General › Your name, Voice › Dictation, Recordings & Podcasts and Text to speech, Images and Videos, Sources › Reading Lists and Zoom Transcripts, Plugins › Google Drive and YouTube, the Activity layout, and the settings with no pane), and the rest have tools of their own below. What stays in the window needs the learner's own hand: signing in, a plugin's consent page, a Stripe payment, Apple's sharing sheet. `open_settings` shows that pane. All of these need the Mac open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `get_app_settings` | `pane?`, `setting?` | Every catalog setting with its `id`, `value`, `type` (`boolean`, `number`, `choice`, `text`, `string_list`), `reach` (`account` or `this_mac`) and the `options` its picker offers, plus `dedicated_tools` (the panes with a pair of their own), `actions` and `only_in_the_settings_window`. |
| `set_app_setting` | `setting`, `value` | Change one catalog setting exactly as the pane does. A choice outside the pane's options is refused with them. Returns the setting and `changed`. Model and voice pickers change what work is billed at; ask first. |
| `run_settings_action` | `action`, `approved_spend_usd?` | One of the buttons that act once, whether or not a pane still shows it: `sync_icloud_now`, `prepare_memory_review_now`, `draw_missing_meeting_icons`, `sync_x_bookmarks`, `clear_usage_ledger_warning`, and the iCloud pane's `confirm_this_mac_holds_my_library`, `upload_library_to_icloud_again`, `apply_old_library_removals` and `keep_old_library_removals`, and `replace_icloud_library`, which only an assistant presses when you ask: it deletes iCloud's copy of your library and uploads this Mac's from the start. |
| `open_settings` | `pane?` | Open the Settings window on the Mac at one pane, for a sign-in, a payment or the sharing sheet. `plugins` and a plugin's id (`x`, `youtube`, `google_drive`, `apple_calendar`, `slack`, `linear`, `github`, `notion`, `build_your_own_plugin`) open the Plugins place on the icon strip instead, at that plugin's page, where its consent page is opened. |
| `open_in_app` | `kind`, `id?`, `side_by_side?` | Show a notebook, doc, chat, source, quiz or idea in the Mac's window as a click would, `space` (the Space's All list), or `plugins` (the Plugins place, at a plugin's page when `id` names one). Listing or loading a notebook changes nothing on screen; this does. |
| `get_plugin_connections` | `include_slack_channels?` | Plugins: which of X, YouTube, Google Drive, Calendar (the Mac's), Slack, GitHub, Linear, Notion and the learner's own plugins are connected, their accounts (every X, YouTube and Google account listed on its own, a YouTube account with its import source), Slack channels, followed and hidden YouTube channels, and what connecting each takes. |
| `disconnect_plugin` | `plugin`, `account_id?` | The pane's Disconnect, Turn Off or Remove Access for `x`, `youtube`, `google_drive`, `apple_calendar`, `slack`, `github`, `linear`, `notion` or `user_plugin`. `x` takes the account as `account_id` (its user id or @username) when more than one is connected, and disconnects that account only: its bookmark sync stops and the posts already imported stay. `youtube` takes the account as `account_id` (its channel id, or its channel title) when more than one is connected, and disconnects that account only: it stops importing, while followed channels and the videos already imported stay. `linear` and `notion` take the workspace as `account_id` (its id, or its name) when more than one is connected, and revoke that workspace only. `apple_calendar` turns the Mac's Calendar off for ForeverLM; every event stays in the calendar. Ask first. |
| `set_slack_channel_enabled` | `channel_id`, `enabled`, `team_id?` | A Slack channel's switch in Plugins › Slack. |
| `get_calendar_settings` | — | Plugins › Calendar: whether the Mac's Calendar is on for ForeverLM and macOS granted access, every calendar the Mac holds (iCloud, Google, Exchange, subscriptions) with whether it takes new events (`writable`) and whether it is part of the day (`on_day`), and `new_events_calendar`, where new events go. |
| `set_calendar_settings` | `apple_calendar_enabled?`, `apple_calendar_ids?`, `new_events_calendar_id?` | Turn the Mac's Calendar on (may show the macOS permission prompt) or off, set the whole list of calendars that make up the day, or choose the calendar new events go to (`""` for the Calendar app's default). |
| `follow_youtube_channel` | `channel` | Follow a channel by address or @handle, as Plugins › YouTube does. |
| `unfollow_youtube_channel` | `group_id` | Stop following a channel. |
| `rename_team` | `team_id`, `name` | Rename a team the learner owns. |
| `delete_team` | `team_id` | Delete a team the learner owns, for every member. Ask first. |
| `leave_team` | `team_id` | Leave a team the learner is a member of. Ask first. |
| `open_team_library` | `team_id?` | Show a team's library in the Studio, or My Library without `team_id`. |
| `get_team_invitation_link` | `team_id` | The team's invitation link, as Copy Link gives it. For an owner this opens the team to anyone with the link; ask first. |
| `get_chat_models_offered` | — | The models the chat picker offers, with the default. |
| `set_chat_model_offered` | `provider`, `model`, `offered`, `remove_from_catalog?` | Offer a model in the chat picker or take it off, adding an OpenRouter model from its directory when needed; `remove_from_catalog` drops a model the learner added. The Default Model cannot be taken off. |
| `get_billing_settings` | — | Settings › Billing, which is MCP's plan (whether MCP is in its 7 free days, paid once, on a monthly plan bought earlier, comped, covered by a family plan, or locked; a locked MCP stops assistants, never the app) and Settings › AI Usage (a summary of your own OpenRouter key, any leftover balance, and the monthly spending limit and its options). |
| `set_billing_settings` | `monthly_spending_limit` | Set the monthly limit. Paying for MCP needs Stripe Checkout, so it points at `open_settings billing`. Ask first. |
| `get_background_ai_jobs` | — | Bulk re-queues waiting before they spend: when an update puts more than 50 sources into a paid background queue (source clean-up, Listen preparation, podcast ad clean-up), nothing runs until you decide. Each job's count, how many the change affects, and an estimate from your own usage ledger (or "unknown"), plus today's background spend against the daily cap. |
| `decide_background_ai_job` | `job_id`, `decision` | Run all of a held re-queue, only the sources the change affects, or skip it. Running spends money, so the assistant asks first. A run can be stopped later with `cancel_ai_work`. |

## Stopping paid work

Anything an assistant starts that spends money can be stopped from the chat:
a long tool call still writing (a course's quizzes, a course, a walkthrough, a
transcription), even one whose assistant stopped waiting for it; an explainer
video being filmed; a mnemonic reading's questions being written; the
text-to-speech queue; Teachable transcripts made in the
background; a scheduled task running on this Mac; and a bulk re-queue released
to the background drains. What was finished before the stop is kept. These
answer from the active Mac, and at once, even while a long call is still
writing to the library.

Paid assistant tools also take `approved_spend_usd`. Omit it for the $3
per-operation ceiling. Once durable usage for the operation reaches that
amount, the request in flight finishes, completed work stays, and the workflow
starts no further paid request. The assistant must show the estimate or
published maximum and receive explicit approval before passing a larger total.
Whenever the connected client can author an artifact with its own included
allowance, it should do that first and save the result with ForeverLM's write
tools instead of calling a paid ForeverLM generator.

| Tool | Parameters | Description |
|---|---|---|
| `list_running_ai_work` | — | What is running now, each with its `work_id`, what started it, what it is about, how long it has run, whether it spends money, its recorded spend, and its approved ceiling. The app's own paid steps (Text-to-Speech Preparation, Paper Metadata, a recording's transcription, a notebook's cover) are listed one entry a step, automatic audio as its own entry, and `stopped_steps` names the steps stopped until you resume them. |
| `cancel_ai_work` | `work_ids?`, `all?` | Stop work by `work_id`, or everything that spends money with `all`. A stopped bulk re-queue waits for a decision again in `get_background_ai_jobs`. A stopped step that runs on its own, or automatic audio, stays stopped on every Mac until it is resumed, though what you ask for yourself still runs; a step you asked for is only cancelled. |
| `resume_ai_work` | `steps?`, `all?` | Let stopped steps run again, by the `task` values `list_running_ai_work` gives under `stopped_steps`, or every one with `all`, as **Resume** does in the app. |

## Text-to-speech audio

The app's Generate Audio, for many sources at once. The voice is the one chosen
in ForeverLM Settings and the route is the same metered one the app uses, so a
source that already has audio is never billed again. These need an active Mac:
narration is generated and stored by the app, and the queue that paces a whole
library through the provider runs there.

| Tool | Parameters | Description |
|---|---|---|
| `generate_source_audio` | `source_ids?`, `book_ids?`, `source_types?`, `confirm_cost?`, `allow_unsupported_languages?`, `approved_spend_usd?` | Queue text-to-speech generation for individual sources, whole books (chapters in reading order), or every source of a type — `["book"]` is every book in the library. When it costs money the first call only returns an estimate; the assistant shows it to you and calls again with `confirm_cost` after you agree. |
| `get_source_audio_status` | `source_ids?` | What is generating, queued, finished, failed, skipped, or cancelled, with reasons; optionally whether specific sources already have audio. |
| `cancel_source_audio_generation` | `source_ids?`, `all?` | Stop queued or running generation. Finished chunks stay cached. |
| `generate_audio_overview` | `notebook_id`, `source_ids?`, `format?`, `length?`, `focus?`, `generate_audio?`, `confirm_cost?`, `approved_spend_usd?` | A Notebook's audio overview, as its Studio makes it: one spoken script over the Notebook's own ticked sources: `deep_dive` (about 7, 12 or 19 minutes), `brief` (about 2) or `critique` (about 5, 8 or 13), led by an optional focus, written by your Audio Overview Writing model and narrated by your text-to-speech voice. Sources too long for the model's window together are read from their stored ideas or a condensed account of their whole text, and the answer says which; nothing is cut. The first call prices the writing and the audio, and starts nothing while the voice costs money until you agree. Then the writing runs in the background (`work_id`; `cancel_ai_work` stops it), and `get_source_audio_status` with its `audio_source_id` follows the script and then its audio. It is saved as an `audio_overview` page in the Notebook. |

## Explainers

An explainer retells one source, or one concept, for someone new to it.

| Tool | Parameters | Description |
|---|---|---|
| `generate_explainer` | `source_id`, `length?`, `generate_audio?`, `confirm_cost?`, `approved_spend_usd?` | A spoken explainer of a paper or article: a plain-language script for the ear by your Explainer Writing model (`brief` about four minutes, `standard` about seven, `extended` about twelve), saved as a source titled "Explainer: …" and listed under the original, then narrated as `generate_source_audio` does unless `generate_audio` is false. A paid voice waits for your agreement to its estimate, unless automatic audio is on for explainers. A second call replaces the explainer. |
| `generate_explainer_video` | `concept`, `source_id?`, `notebook_id?`, `lecture_id?`, `length?`, `approved_spend_usd?` | A short explainer video of one concept, made on the Mac: storyboarded in eight-second scenes by your Explainer Writing model and filmed by your video model (Settings › Videos), kept under Videos, or as a course module's video with `lecture_id`. ForeverLM asks you the exact price in a dialog on the Mac before anything is filmed; the call returns once you answer. |

## Reader highlights and notes

A highlight's `color` is one of five, each with a meaning the reader shows: `yellow` (Remember), `green` (Key idea), `blue` (Follow up), `pink` (Doubt) and `purple` (Connect). Every tool here that returns a highlight carries `color_meaning` beside `color`; pick a color by what the mark is for.

The passages the learner marked while reading, and the notes they wrote on them.
A mark is anchored to the source's own wording rather than to a character
offset, so one created here paints in every ForeverLM reader and survives the
source being re-fetched.

| Tool | Parameters | Description |
|---|---|---|
| `list_source_highlights` | `source_id` | List one source's highlights with the note, color (and its meaning), and page on each, the `publication_update` (what has been learned since the source was written, apart from the learner's note) and when it was written, the `session_id` and `chat_title` of the chat a note came from, and the `references` the note cites, each with its library `source_id` when the library holds it. |
| `search_source_highlights` | `query?`, `color?`, `limit?` | Search every highlight, note and since-publication update in the library, newest first. Omit `query` for the most recent marks. Pass `color` to see one marker color across the library: `blue` (Follow up) is what the learner set aside to come back to, `pink` (Doubt) what they doubt. |
| `create_source_highlight` | `source_id`, `quote?`, `image_url?`, `image_alt?`, `note?`, `publication_update?`, `color?`, `session_id?`, `references?` | Mark a passage, quoted verbatim from `get_source_content`, or a picture of a web page by its `image_url` (with no quote), or both at once. A passage that is not found, or a passage or picture already marked, is refused. Highlights on pictures carry a `pictures` list and an empty quote. `session_id` links the chat the note came from, and the reader opens it from the mark: research into what has been published since a textbook was written is saved with `import_review_chat` (`mark_reviewed: false`) and linked to the passage it updates this way, with its short version as `publication_update` (a one-sentence headline line, then the detail), never as `note`, which is the learner's. `references` lists the papers the note cites (each a `citation` and a `doi` or `url`, `title` optional, at most 20); the reader shows them on the mark with Add to Library, or Open when the library holds one. |
| `update_source_highlight` | `highlight_id`, `note?`, `publication_update?`, `color?`, `session_id?`, `references?` | Rewrite the note or the since-publication update (an empty one clears it), change the color, link the chat the note came from, or replace the papers it cites. An empty note leaves a bare highlight; an empty `session_id` unlinks the chat; an empty `references` list clears the papers. |
| `delete_source_highlight` | `highlight_id` | Remove a highlight and its note. |

## Notebooks

A notebook is an explicit scope. The plugin never infers one from the notebook
open in the app. A notebook's chats read its own ticked sources, plus those of
the notebooks it lists under **Uses context from** (its context notebooks) that
you put into its chats; linking a notebook alone puts nothing in. Responses
identify the context notebook rather than presenting its sources as copied
membership. What a notebook's Studio makes reads only its own ticked sources.

| Tool | Parameters | Description |
|---|---|---|
| `list_notebooks` | `include_completed?` | List Notebooks, the app's notebooks, and their source counts; a notebook the learner names is found here by its title. Each Notebook carries `team_id` (null for a personal Notebook) and, for a team Notebook, `team_name`. |
| `get_notebook` | `notebook_id` | Return one Notebook's instructions, research questions, notes, open gaps, and source IDs, with `team_id` and `team_name` when the Notebook is a team's, and the GitHub `repository` it is about as `owner/repo` (null when none). A linked repository is read live through the GitHub tools; nothing from it is stored. `think_first` is the Notebook's own Think first level (null when it follows the library's) and `think_first_level` the level that applies. |
| `create_notebook` | `title?`, `instructions?`, `summary?`, `topic?`, `source_ids?`, `daily_target?`, `discover?`, `research_questions?`, `repository?`, `allow_duplicate?` | Create a Notebook and seed it with existing sources. A Notebook is open-ended: a deadline belongs on a Goal (`create_learning_goal` with `notebook_id`). A title that matches an existing Notebook is refused unless `allow_duplicate` is true. Without `title` the Notebook is "New notebook" until ForeverLM names it, title and card description, from its sources and first chat; a `title` or `summary` given here or with `update_notebook` is never renamed. `discover` ranks the library with its own search, for the Notebook's topic and for the words its own sources use and few others do, and keeps only the sources the Background model judges to serve the Notebook (the judgment Journal Watch makes of new articles), added as suggestions to keep or drop; it needs an active Mac with AI set up. Called from ForeverLM's own chat, the Notebook starts with the sources that chat discussed (the one it was opened on and the ones its replies linked, after any `source_ids`, up to six in all), takes the chat in, and the chat's window opens it. |
| `add_notebook_sources` | `notebook_id`, `source_ids` | Attach existing sources to a Notebook's approved pool. Sources already in the Notebook are skipped. New material can be filed in one call: `add_source`, `add_sources` and `import_paper_from_url` take `notebook_id`. |
| `discover_sources` | `notebook_id`, `query?`, `count?`, `source_ids?`, `approved_spend_usd?` | Find sources a Notebook is missing, as a notebook's Discover does: one web search on the chat's model with the Notebook's title, instructions, research questions and sources as context. Returns a one-sentence summary and up to `count` candidates (5 to 15, default 10), each with one line on why it fits. An address is kept only when the search engine cited it, Crossref knows its DOI, or the page opens (`left_out` counts the rest); an address that is never a source, such as a home or search page, a Google Doc, a Gemini notebook, a YouTube playlist or a YouTube page that is not a video, is set aside (`not_sources` counts them, present when any were); and each candidate's kind is read off its address. Each candidate says whether the library (`in_library`, `library_source_id`) or the Notebook (`in_notebook`) already holds it. Nothing is imported: import the ones the learner picks with `import_paper_from_url` or `add_sources`, then `add_notebook_sources`. For papers, `search_literature` searches PubMed for free. Refused before anything is spent when the chat's model cannot search the web. Needs the learner's Mac open and connected. |
| `list_notebook_sources` | `notebook_id` | List approved sources and understanding state for one Notebook: its own sources, then each context notebook's, marked `via_context_notebook_id` and `via_context_notebook_title`. `in_chat` is true for a source a new chat in the Notebook reads, and `context_notebooks` says which context notebooks you put into its chats. Each source carries `link`, its title as the in-app link a reply shows in place of the id. |
| `set_notebook_source_selection` | `notebook_id`, `mode`, `source_ids?`, `context_notebook_ids?` | Tick or untick a Notebook's sources for its chats, the checkboxes beside a notebook's sources in the app, and put its context notebooks into its chats or take them out. `mode` is `include`, `exclude` or `only` (with `source_ids`, `context_notebook_ids` or both), or `all` or `none`. A Notebook's own sources start ticked; a context notebook's reach its chats only once put in, which keeps any of its sources you unticked unticked (including one already in ticks every source of it, as its box does), and ticking one source of a context notebook that is out puts it in with that source alone. The choice is your own and changes no membership or link; new chats, and a chat not yet sent, read the ticked sources, while a chat under way keeps its own. `list_notebook_sources` reports `in_chat` for each source. Answered by the Mac app. |
| `list_notebook_collections` | — | List the learner's collections of Notebooks, the Collections the Space groups notebooks by: each one's id, name and the `notebook_ids` in it. A Notebook can be in any number of collections, or none. Answered by the Mac app. |
| `update_notebook_collection` | `action`, `collection_id?`, `name?`, `notebook_ids?` | Make (`create`, with `name` and optional `notebook_ids`), rename (`rename`), or delete (`delete`, its Notebooks stay as they are) a collection, or put Notebooks in or take them out (`add_notebooks`, `remove_notebooks`). A collection changes nothing about a Notebook and follows the learner's account. Answered by the Mac app. |
| `get_notebook_context` | `notebook_id`, `max_source_chars?`, `include_emergent_state?`, `include_source_content?` | Return Notebook metadata, the sources its chats read (its own ticked sources and those of the context notebooks put into its chats, with those notebooks' details), open gaps, artifact metadata, review state, and optional source excerpts, and say what is left out. Notebook workspace-file bodies and artifact Markdown live in iCloud Drive and are unavailable to the always-on hosted service; the response reports that limitation explicitly. |
| `merge_notebooks` | `notebook_ids`, `title?`, `merge_notes?` | Fold Notebooks into the first id, the survivor: source pools are unioned, and the merged Notebooks' chats, Goals, tasks, Pages, courses, scheduled tasks, Schedule placements, Ideas' links, Directions and workspace files move to it; open questions are deduped, research questions unioned, notes concatenated. The merged Notebooks are deleted. All must be in one library. Answers `sources_added`, `chats_moved`, `goals_moved`, `tasks_moved`, `docs_moved` and `files_moved`. |
| `update_notebook` | `notebook_id`, `title?`, `summary?`, `instructions?`, `topic?`, `research_questions?`, `related_notebook_ids?`, `repository?`, `think_first?`, `daily_target?`, `discover?`, `status?` | Change a Notebook's settings, or archive and restore it. `related_notebook_ids` replaces its whole set of context notebooks (linking puts nothing into its chats; `set_notebook_source_selection` does). `instructions: ""` clears them and `repository: ""` unlinks the GitHub repository. Archiving hides the Notebook from the usual lists and deletes nothing. |
| `update_notebook_notes` | `notebook_id`, `markdown` | Replace a Notebook's synthesis notes, the record of what the learner understands. |
| `append_notebook_notes` | `notebook_id`, `markdown` | Add Markdown to the end of a Notebook's notes without replacing them. |
| `reorder_notebook_sources` | `notebook_id`, `source_ids` | Set the study order of a Notebook's sources: those listed come first, in that order, and the rest keep theirs after them. |
| `split_notebook` | `notebook_id`, `splits`, `keep_parent?` | Split a broad Notebook into focused child notebooks, moving each source (and its open questions) to exactly one child; nothing is copied. A team's Notebook splits into that team. |
| `delete_notebook` | `notebook_id`, `delete_chats?` | Delete a Notebook for good: its pool, planning state, open questions, notes and the Goals inside it; its workspace files go to the Trash and its sources stay in the library. Its chats stay, ungrouped, unless `delete_chats`. Not undoable: confirm the name and the Goal count first. |
| `list_open_questions` | `notebook_id`, `status?`, `include_resolved?` | A Notebook's open questions: the research gaps the learner is chasing, with no deadline. |
| `create_open_question` | `notebook_id`, `summary`, `severity?`, `source_id?`, `status?` | Add an open question. It is not a Goal: a goal the learner voices is `create_learning_goal`, with a deadline. Reviews add open questions too. |
| `update_open_question` | `notebook_id`, `question_id`, `summary?`, `status?`, `severity?`, `source_id?`, `clear_source_link?` | Change an open question's status, wording, linked source or severity. |
| `list_notebook_files` | `notebook_id` | A Notebook's workspace files, marking the Markdown ones the next two tools read and write. |
| `read_notebook_markdown_file` | `notebook_id`, `path` | Read one Markdown workspace file in full, with its SHA-256 revision. |
| `write_notebook_markdown_file` | `notebook_id`, `path`, `markdown`, `expected_revision?` | Create a Markdown workspace file, or replace one by passing the revision you read; a stale revision is refused rather than overwriting newer work. |

## Goals

A Goal has a deadline and the sources paced toward it. It can be about learning
("learn about GDF15 this week") or an outcome ("write an article about
mitochondrial transplantation", where the title is the deliverable). A Goal
stands on its own or is tagged to a notebook, and several run at once. The
deadline is never invented: when the learner names none, the assistant proposes
a date with its reasoning and confirms it first.

| Tool | Parameters | Description |
|---|---|---|
| `list_goals` | `notebook_id?`, `include_completed?` | The learner's Goals: deadline, days left, approved and completed source counts, review status, and the Page, site or animation each is for (`artifact`). Without `notebook_id`, every Goal, tagged to a notebook or standing alone. |
| `get_goal` | `goal_id` | One Goal in full: deadline, days left, whether it is overdue, status, its notebook, its `artifact`, its approved and pending sources, and open questions. `get_schedule` with its `goal_id` shows the days its sources are on. |
| `create_learning_goal` | `title`, `end_date`, `start_date?`, `topic?`, `notebook_id?`, `source_ids?`, `artifact_id?`, `daily_target?`, `discover?` | Create a Goal. `notebook_id` only tags it to an existing notebook, so no notebook is made to hold it. `discover` finds related sources already in the library and adds them as suggestions to approve with `review_suggested_sources`; `assign_sources_to_day` then paces them. |
| `update_learning_goal` | `goal_id`, `title?`, `description?`, `topic?`, `end_date?`, `daily_target?`, `discover?`, `notebook_id?`, `artifact_id?`, `status?` | Change a Goal, tag it to another notebook or none, link it to the Page, site or animation it is for, or mark it done or archived, keeping its sources and history. After a new deadline, re-pace its sources with `assign_sources_to_day`. |
| `add_goal_sources` | `goal_id`, `source_ids` | Put library sources on a Goal at once, with no approval step; a Goal tagged to a notebook hands them on to it. A notebook is refused (`add_notebook_sources`). |
| `review_suggested_sources` | `goal_id`, `approve?`, `reject?` | Approve or reject the sources ForeverLM suggested for a Goal. A rejected source is never suggested again. |
| `reorder_goals` | `goal_ids` | Put Goals in an order: those listed first, in that order, the rest after them as they already read; `[]` goes back to deadline order. |
| `delete_learning_goal` | `goal_id` | Delete a Goal for good: its record, pool and Schedule tags. Its sources stay, and a chat started from it stays with the link cleared. To put it away instead, archive it with `update_learning_goal`. Not undoable. |
| `list_learning_goals` | `include_completed?` | The older combined listing of notebooks and Goals; `list_notebooks` and `list_goals` replace it. |
| `add_companion_sources` | `goal_id`, `source_ids` | The older form of `add_notebook_sources` and `add_goal_sources`, which check the kind of record they are given. |

## Teams and tasks

A team is a shared library: a CloudKit zone in its owner's iCloud that members
receive through Apple's sharing, with no server copy at ForeverLM. Sharing
copies: a source, notebook, Page or chat put into a team gets a team-scoped copy
and the original stays where it was, so leaving a team never removes anything
from anyone's own library. Sharing the same item twice updates the copy. A chat
shares as a read-only transcript with the learner's scores, ratings and reading
context stripped. Members are invited from ForeverLM itself, through Apple's
sharing sheet; `share_notebook` returns the team's invitation link to hand on.

Sharing gives the team's members copies of sources, so the learner affirms once,
in ForeverLM or through an assistant, that they have the right to share them.
Until they have, `share_notebook`, `share_with_team` (every kind but a chat) and
`fulfil_share_request` refuse with the question to ask the learner; pass `rights_affirmed_by_learner:
true` only after asking it and hearing yes. The answer is kept with the learner's
account and not asked again.

Every notebook carries a task board. In a team notebook the tasks are the team's
and can be assigned to a member by `user_record_name`, the stable CloudKit
identity the roster in `list_teams` reports; a personal notebook's tasks take no
assignee. A team's roster, copies and board are kept by the app, so every tool
here needs an active Mac; without one, the call is refused with an explanation
rather than answered. Writes into a team that is read-only for the learner are
refused.

| Tool | Parameters | Description |
|---|---|---|
| `list_teams` | — | List every team the learner owns or joined: role, permission, the roster with `user_record_name`, `display_name` and `is_current_user`, and the invitation `share_url` when known. |
| `create_team` | `name` | Create a team the learner owns, stored in the learner's own iCloud. Returns the team. |
| `share_with_team` | `team_id`, `kind`, `ids`, `include_sources?`, `include_docs?`, `include_chats?`, `include_cited_sources?`, `rights_affirmed_by_learner?` | Copy sources, Notebooks, Pages, chats or courses (`kind`) into the team. Originals stay; a Notebook travels with its Goals and by default its sources, Pages and chats, and whatever is filed under it afterwards follows it into the team; a chat becomes a read-only transcript; a course travels with its lectures, readings, quizzes and every source on its path (`course_sources_shared`), and each member takes it with their own progress. A Page, site or animation travels with its sources: the sources its record links are copied into the team and the copy names the team's copies (`linked_sources_shared`), and the web sources its body cites that My Library holds and the team does not (papers and books, or anything with a file on the Mac) come along too (`cited_sources_shared`) unless `include_cited_sources` is `false`; a source that could not be copied is listed under `sources_not_shared` and does not stop the share. Returns the team copy id for every original. |
| `share_notebook` | `notebook_id`, `rights_affirmed_by_learner?`, `team_id?` | Share a notebook with people in one call, as its **Share…** does in ForeverLM. A notebook already in one team uses that team; a notebook in no team gets a new team named after it (its title, emoji included), holding a copy of the notebook with all its approved sources and their files, its Goals, Pages and chats, and what is filed in the notebook later follows it there. `team_id` names the team: needed for a notebook two teams hold, or to share it into another of the learner's teams; a team that already has the notebook gets nothing copied again. Returns `team_id`, `team_name`, `created_team`, `shared_sources`, `team_notebook_id` (the team's notebook), the `members` with their role and whether they accepted, `invitation_link`: the link **Copy Invitation Link** copies (`null` until iCloud has shared a new team, the reason in `message`), `link_opens_to_anyone`: `true` when the link opens a team the learner owns to anyone who has it, with editing, and `message`. Refused, naming the owner, when the learner can only read the team. |
| `list_notebook_tasks` | `notebook_id`, `status?`, `assignee?` | List a Notebook's tasks with every field. Filter by `status` (`todo`, `doing`, `done`) or, in a team Notebook, by `assignee` (`user_record_name` or `me`). A team Notebook's response includes the team and its roster. |
| `create_notebook_task` | `notebook_id`, `title`, `notes?`, `status?`, `assignee_record_name?`, `due_date?`, `source_id?`, `doc_id?` | Add a task. `assignee_record_name` (a member's `user_record_name` or `me`) applies to team Notebooks only; `due_date` is `YYYY-MM-DD`. |
| `update_notebook_task` | `task_id`, `title?`, `notes?`, `status?`, `assignee_record_name?`, `due_date?`, `source_id?`, `doc_id?` | Change a task; omitted fields keep their value. `assignee_record_name` `""` unassigns and `due_date` `""` clears the date. Setting `done` stamps the completion. |
| `delete_notebook_task` | `task_id` | Delete a task; in a team Notebook every member loses it. Not undoable. |
| `assign_to_member` | `team_id`, `member`, `source_ids?`, `doc_id?`, `due_date?`, `notes?` | Assign something to learn to one member (a child, in a family team). Each source or Page is copied into the team and becomes a task for the member on the team's Assignments board; the task marks itself done when they read the source to the end or review it. `member` is a `user_record_name` or a display name unique in the team. |
| `list_assignments` | `team_id?`, `mine?`, `include_done?` | With `mine` (the default without `team_id`): what others assigned to the learner, in every team. With `team_id`: that team's Assignments board, every member's, with status and completion. |
| `get_family_plan` | — | For each team, whether the learner's plan covers its members (`family_plan`) and, per member, whether their Mac has joined and has an OpenRouter key; and `membership` when another account's plan covers the learner. |
| `set_family_plan` | `team_id`, `enabled` | Owner only. On (needs the learner's own plan) makes their plan cover every member of the team; off ends it. |
| `connect_family_member_key` | `team_id`, `member` | Make an OpenRouter key for one member through OpenRouter's sign-in in the Mac's browser, and hand it to their Mac sealed to its device key. Waits up to five minutes for the sign-in. |
| `request_share` | `team_id`, `url`, `title?`, `doc_id?` | Ask a team for a source its library lacks: the route for a paper or a book a card on a team Page cannot add because it is not open on the web while a teammate holds it. The request lives in the team zone, so every member sees it; asking again for a standing request returns it, and a source the team already holds is refused. Returns the request with `can_fulfil`, whether this Mac's own library could answer it. |
| `list_share_requests` | `team_id?`, `status?` | A team's requests (or every team's): who asked, from which Page, when, and for open ones `can_fulfil`. `status` is `open` (default), `fulfilled`, `declined` or `all`. |
| `fulfil_share_request` | `request_id`, `rights_affirmed_by_learner?` | Answer an open request with My Library's copy: the source is shared into the team, file included, and the request records the `team_copy_id`. Refused when My Library does not hold it, when the request is closed, or when the learner can only read the team; until the learner has affirmed that they may share their sources, refused with the question to ask them first. |
| `decline_share_request` | `request_id` | Close an open request without sharing; every member sees it closed. |

## Pages

Pages were called Docs before 2026-10; the tool names keep the old word.

Pages are canonical Markdown documents, rendered and editable in ForeverLM's
Pages pane and linkable to any number of notebooks. They are the home for
anything an assistant writes itself: a research report, a comparison, a
synthesis. A source added with `add_source` shows its text verbatim in the
reader, so Markdown filed that way is not rendered. Page bodies are stored by
the app, so every Page tool needs an active Mac; without one, the call is
refused with an explanation rather than answered.

| Tool | Parameters | Description |
|---|---|---|
| `list_docs` | `notebook_id?` | List Pages, or only the Pages linked to one Notebook. A `google_doc` kind is a linked Google Doc, read-only here; `claude_artifact`, `codex_site` and `foreverlm_site` are linked pages the app lists in its Sites section, also read-only; `animation` is an animation (`section: animations`), with the sources it explains in `source_ids`. `team_id` is the library the row is in: null for My Library, else the team whose copy it is. `published_access_summary` is the sentence the Page's Share popover says about who can open it ("Only you can open this Page", "Anyone with the link can open this page", "Only the 3 people listed can open this page · shared with OxPhos"); change it with `publish_doc`'s `readers` and `share_with_team`. `space_id` and `space_name` name the learner's space of pages the Page is in (`list_spaces`), null when it is in none. |
| `create_doc` | `title`, `markdown?`, `home_notebook_id?`, `notebook_ids?`, `is_draft?` | Create a Page from complete Markdown and link it to Notebooks. |
| `generate_report` | `notebook_id`, `format?`, `focus?`, `instruction?`, `subject_id?`, `source_ids?`, `take?`, `confirm_cost?`, `approved_spend_usd?` | A Notebook's report, as its Studio makes it, saved as a Page in the Notebook: `briefing`, `study_guide` (an overview, a ten-question quiz with its answer key, essay questions and a glossary), `meeting_questions`, `document_feedback` (on `subject_id`, one of the Notebook's sources or Pages, judged against the rest) or `custom` (your `instruction`), with an optional `focus`. `take` is the learner's own view, in their words, written before seeing the report (Think first): the Page opens with it under Your take and ends with Where this differs from your take, never a grade. Written by your Report Writing model over the Notebook's own ticked sources, never a context notebook's; sources too long for the model's window together are read from their stored ideas or a condensed account of their whole text, and the answer says which, so nothing is cut. Each passage stands on the sources it cites, and the Page ends with a card for each source and the recipe it was made from. The first call prices the writing and starts nothing until you agree, unless the model is free; then it is written in the background (`work_id` and `doc_id`; `cancel_ai_work` stops it), and `read_doc` returns it once saved. |
| `read_doc` | `doc_id`, `start?`, `length?`, `resolve_references?` | Return the Page's Markdown and its SHA-256 revision, in full or by character range. `resolve_references` returns it as a reader outside ForeverLM sees it: each `((id))` block reference as the block's words, each embed as the block, `[[Title]]` and `#tag` links as their words. |
| `write_doc` | `doc_id`, `markdown`, `expected_revision`, `publish?` | Replace the complete Markdown, for a short Page or a full rewrite; refused when the revision no longer matches `read_doc`, or for a linked page (the refusal says how to refresh the copy or unlink). `publish: true` updates the Page's published web page in the same call; a Page that is not published is not published by it. |
| `edit_doc` | `doc_id`, `edits?`, `append?`, `expected_revision`, `publish?` | Change parts of a Page in place: each edit gives the exact text to find and its replacement (one match, or `replace_all`), and `append` adds Markdown at the end. All-or-nothing, any Page length; the body never travels in the call. When the Page changed after `read_doc` (the learner typing in it), the edits apply to the newer text as long as every `find` still matches once, and the result says `doc_changed_meanwhile`. A published Page's web page is not re-rendered until `publish_doc`. `publish: true` updates the Page's published web page in the same call. |
| `update_doc` | `doc_id`, `title?`, `home_notebook_id?`, `notebook_ids?`, `is_draft?`, `is_archived?`, `is_hidden?` | Rename, change Draft status, archive or restore, hide or show (the learner's own view, synced across their Macs, never a teammate's), or replace the Notebook links without touching the body. |
| `delete_doc` | `doc_id` | Move a Page to the Trash, or remove a linked page from Pages or Sites without touching the page itself. Not undoable; confirm the title first. |
| `list_doc_versions` | `doc_id`, `version_id?`, `start?`, `length?` | The Page's earlier versions that the Mac keeps, the Page's **Page activity**, newest first: each one's `version_id`, `saved_at`, `reason` (what replaced that body: `learner_edit`, `assistant_edit`, `another_device` or `restore`), the app's `summary` and its size in `bytes`, with the current body's revision and size. A version is kept when an assistant or a restore replaces the body, every ten minutes of typing, and when the page loses more than half its text at once. `version_id` returns that version's Markdown too, whole or by range as `read_doc` reads. Versions are the Mac's alone, so this needs that Mac open and connected. |
| `restore_doc_version` | `doc_id`, `version_id`, `expected_revision?`, `publish?` | **Restore This Version**: the version becomes the Page's body through the ordinary save, and the body it replaces is kept as a version first, named in `replaced_body_version_id`, so restoring that id undoes it. `expected_revision` refuses the restore when the Page changed since you read it. Refused for a team's page and a linked page, as in the app, and for an audio overview or a mnemonic reading. `publish: true` updates a published Page's web page in the same call. Needs the Mac that kept the version. |
| `list_doc_chats` | `doc_id` | The chats a Page's passages started, each with the quote it was opened on, so a passage already discussed is not started on again. |
| `link_doc_passage_to_chat` | `doc_id`, `session_id`, `quote`, `section_title?` | Record that a chat is about a passage of a Page, as highlighting the passage and opening Chat on it does, for a chat that reached the Page another way. |
| `unlink_doc_chat` | `link_id` | Forget one passage-to-chat link. The Page and the chat stay. |
| `list_doc_comments` | `doc_id`, `include_resolved?` | The comment threads on a Page, as its **Comments** panel shows them, in the order of their passages: each thread's `comment_id`, the `quote` it is about, whether it is `resolved`, and its messages oldest first with `author`, `by_assistant` and `body`. |
| `comment_on_doc` | `body`, `doc_id?`, `quote?`, `reply_to?` | Comment on a Page, signed **Assistant**: with `doc_id` and `quote` (the exact words, at most 1,000 characters) a new thread on those words, which the Page marks where they first occur; with `reply_to` a reply in that comment's thread. Refused for a team's page. |
| `update_doc_comment` | `comment_id`, `body?`, `resolved?` | Rewrite a comment's words, or resolve (`true`) or reopen (`false`) its thread. Refused for a team's page. |
| `delete_doc_comment` | `comment_id`, `whole_thread?` | Delete a comment, its replies kept (the first reply opens the thread when the first comment goes), or with `whole_thread` the thread and every message in it. Not undoable. Refused for a team's page. |
| `get_daily_note` | `date?`, `create?` | The learner's daily note, a Page a day as in Roam Research: its id is `daily-YYYY-MM-DD` and its title the day written out ("October 6th, 2026"), so `[[October 6th, 2026]]` in any Page links it. Writes nothing unless `create`, which makes the day's empty note. |
| `append_to_daily_note` | `markdown`, `date?` | Add Markdown to the end of a day's note (today's by default), making the note when the day has none. Nothing already in it changes. |
| `get_plan` | `date?`, `create?` | Your plan for a quarter, the Pages of the [Plan](/plan) place: its `doc_id` (`plan-2026-q4`), title ("Q4 2026"), the days it spans, its Markdown and revision. `date` is any day in the quarter, its key or title, or `this`, `next` or `last`. Writes nothing unless `create`, which makes the plan from its template; write in it with `edit_doc`. Weeks and days are planned onto the calendar. |
| `get_block` | `block_id`, `team_id?` | Read one block of a Page by its id (the ` ^id` it ends with, which `((id))` references): the Page that holds it, its Markdown and kind, its breadcrumbs, what is nested under it, and how often it is referenced or embedded. |
| `get_linked_references` | `doc_id?`, `idea_id?`, `source_id?`, `block_id?`, `include_unlinked?`, `limit?`, `team_id?` | The Linked References of a Page, an Idea, a source or one block, as Roam lists them: the blocks that point at it, newest edit first, each with its breadcrumbs. `include_unlinked` (Pages only) adds blocks that write the title without linking it. |
| `list_spaces` | none | The learner's spaces of pages, the **Spaces** in the Space sidebar, as ChatGPT's spaces group pages around a topic or a project: each space's `id`, `name` (a leading emoji is its icon) and the Pages, linked Google Docs, sites and readings in it, by title; pages in the Trash are left out, and the spaces in the Space's Trash are listed under `in_trash`. A page is in one space at most. The teams, the shared spaces, are `list_teams`'. Needs the Mac open and connected. |
| `update_space` | `action`, `space_id?`, `name?`, `doc_ids?` | Make (`create`, with `name` and optional `doc_ids`), rename (`rename`), put in the Space's Trash (`trash`; it leaves the sidebar and its pages stay in All), bring back from Trash with its pages (`restore`) or delete for good (`delete`; its pages stay in All) a space, move `doc_ids` into one (`move_docs`, each out of the space it was in), or take them out of their space (`remove_docs`). A team's record, an animation and an audio overview cannot join a space. The change follows the learner's account to their other devices. Needs the Mac open and connected. |
| `list_space_lists` | `include_trash?` | The learner's lists in the Space: lists of Goals and lists of Ideas, items beside their pages and canvases as a to-do list is in ChatGPT's Space, each filed in one of their spaces at most. Each list's `list_id`, `kind` (`goals` or `ideas`), `name`, `created_at`, its `space` (`space_id` and `name`) when it is in one, `pinned`, `in_trash`, and what it holds: for a goals list each Goal's `goal_id`, `title`, `deadline` and `status`; for an ideas list each Idea's `idea_id`, `title` and whether it is `open`. A Goal or an Idea is in one list at most and is still listed by `list_goals` or `list_ideas`. `include_trash` lists the lists in Trash too. Needs the Mac open and connected. |
| `create_space_list` | `kind`, `name?`, `space_id?`, `item_ids?` | Make a list on the learner's word: `kind` is `goals` or `ideas`, `name` defaults to Goals or Ideas, `space_id` (from `list_spaces`) files it in a space, and `item_ids` (Goal ids from `list_goals` for a goals list, Idea ids from `list_ideas` for an ideas list) fill it, each moved out of any list it was in. A new Goal or Idea is made first (`create_learning_goal`, `create_idea`) and then added by its id. Refused in a team's library. Returns the list. Needs the Mac open and connected. |
| `update_space_list` | `list_id`, `name?`, `space_id?`, `pinned?`, `in_trash?`, `add_item_ids?`, `remove_item_ids?` | Change a list as its menu does: rename it, file it in a space (`space_id` from `list_spaces`) or take it out of every space (`space_id: ""`), pin or unpin it in the Space sidebar, move it to Trash or restore it, put Goals or Ideas in it (`add_item_ids`, each moved out of any list it was in) or take them out (`remove_item_ids`). A goals list holds only Goals and an ideas list only Ideas. Pass only what changes; the Goals and Ideas themselves are untouched. Returns the list as it is now. Needs the Mac open and connected. |
| `delete_space_list` | `list_id` | Delete a list forever, on the learner's explicit word: the list, its place in a space and its pin go, on every device. The Goals and Ideas it held stay, in no list. Only a list already in Trash can be deleted (`update_space_list` with `in_trash: true` first), as in the Space. Not undoable. Needs the Mac open and connected. |
| `link_page` | `url`, `title?`, `text?`, `home_notebook_id?`, `notebook_ids?` | Put a page in ForeverLM from its link: a Google Doc lands in Pages; a Claude artifact (`claude.ai/code/artifact/…`) or a Codex site (`….chatgpt.site`) lands in the Sites section. The page opens in ForeverLM as itself; its title and a read-only text copy follow when the app next opens it, or at once when `text` is passed. Calling it again for a page already linked, with `text`, replaces the copy, which is the way to refresh it after editing the page in Claude or Codex. Kinds: `google_doc`, `claude_artifact`, `codex_site`. |
| `unlink_page` | `doc_id` | Turn a linked page back into an editable Markdown Page, with the stored text copy as its body. |
| `adopt_page` | `doc_id`, `markdown?`, `readers?`, `slug?` | Make a linked Codex site, Claude artifact or Google Doc ForeverLM's own: unlink it into a Markdown Page and publish it on foreverlm.com in one call, so `edit_doc` and `write_doc` with `publish` edit it from then on. Pass the page's real Markdown as `markdown` when you have it; otherwise the stored text copy is the body. The original page is not touched. |
| `link_google_doc` | `url`, `title?`, `home_notebook_id?`, `notebook_ids?` | The same call as `link_page`, kept for older clients. |
| `unlink_google_doc` | `doc_id` | The same call as `unlink_page`, kept for older clients. |
| `publish_doc` | `doc_id`, `slug?`, `readers?` | Publish the Page as an unlisted page on foreverlm.com, or update the page it already has at the same address. Pass `slug` for a custom address (`foreverlm.com/share/<slug>`: 3–64 lowercase letters, digits and single hyphens); on a published page a new slug moves it and the old address forwards. Pass `readers`, a list of email addresses (at most 200), to share the page with those people only (each enters their address on the page and follows the link emailed to them), an empty list to open it to anyone with the link, or omit it to keep the current readers. Returns the link. Needs the Mac signed in with Apple. |
| `unpublish_doc` | `doc_id` | Take the Page's foreverlm.com page down; the Page stays in the library. |
| `save_site` | `title?`, `html?`, `files?`, `repository?`, `repository_path?`, `ref?`, `site?`, `remove_files?`, `replace_all?`, `home_notebook_id?`, `notebook_ids?` | Save a website — your HTML, CSS, JavaScript and images, served as written — in the learner's library, or change one saved before (`site` names it by its id): an update carries only the files that change and keeps the others, `remove_files` drops named ones, and `replace_all` makes the passed files the whole site. The site is kept in the library, syncs through the learner's own iCloud (up to 45 MB), opens in the Sites section, and is read by chat through its text copy; nothing goes on the web. Files come inline (`html` for one page, `files` for several, `index.html` required for a new site) or from a GitHub repository folder read through the plugin (text files; the commit is recorded). Every page runs in a browser sandbox: scripts run, but `localStorage` and cookies throw. A standalone link to `foreverlm://source/<id>`, or to the web address of a source the library holds (matched by URL, DOI or arXiv id), becomes the library's banner card — thumbnail, title, author · venue · year — and opens Reader in the app: the Mac stores the thumbnails and a card script under `foreverlm/` in the site's files, and the result names `unresolved_sources` and `linked_addresses`. |
| `read_site_file` | `site`, `path?` | With `path`, return one file of a site in the library — text as `content`, an image as `content_base64` — to change it and save again; without it, list the site's files. `site` may also be an animation's id. |
| `replace_site_text` | `site`, `find`, `replace`, `path?` | Change one passage of a site in the library without rewriting the page — the app's **Change** action on a selection in an open Site. `find` is the text as it reads on the page (one line, or consecutive lines such as a kicker and its heading); `path` is a file inside the site or the page's address, the entry page by default. The passage must occur exactly once in the page's source — scripts, styles, comments and attributes never match — or the call is refused with the count; the site is saved in the library with every other file kept, and the result carries the address, the path and a one-line diff. |
| `save_animation` | `title?`, `description?`, `html?`, `files?`, `sources?`, `animation?`, `remove_files?`, `replace_all?`, `home_notebook_id?`, `notebook_ids?` | Save an animation — a moving explanation of how something in a source works, drawn as HTML with inline SVG or Canvas and JavaScript, or rendered to a video file — kept in the library like a site (synced through the learner's iCloud, up to 45 MB), listed in the app's Animations section, and linked to the sources it explains. Files come as `html`, or `files` with `content`, `content_base64`, or `local_path` (a file on the Mac, read from disk — how a Manim render is saved); exactly one video file with no `index.html` gets a player page written around it. `sources` names the papers or articles it explains (ids, `foreverlm://source/<id>` links, or web addresses the library holds); a new animation whose sources resolve to nothing is refused, and `sources: []` saves one about no source. `animation` names one to update, carrying only the files that change; `sources` on an update replace the linked ones. It opens in ForeverLM, like a site; nothing goes on the web. |
| `list_source_artifacts` | `source_id` | The artifacts a source is linked to, shown by the app's **Linked in** menu on a source: every Page, site and animation with `linked_by` naming how (`grounded`: the record's own source links name it, a book standing for its chapters; `cited`: a Page's body holds its DOI or page address, or a `foreverlm://source` link), plus `artifact_id`, `url` and the record fields `list_docs` reports. A Page that mentions a paper without linking it is not listed. |
| `list_animations` | `source_id?`, `notebook_id?` | List every animation, only those about one source, or only those that live in one Notebook (its home or a link; explaining one of its sources is not enough). Each entry carries its library `url`, `sources`, a `summary`, `has_walkthrough` (whether the chat can walk the learner through it), and the record fields `list_docs` reports. |
| `delete_animation` | `animation` | Take an animation's files down and remove its Animations entry. Not undoable; confirm first. Refused for a Site. |
| `generate_walkthrough` | `source_id`, `animations?`, `approved_spend_usd?` | Write a guided walkthrough of a paper, a book chapter or an article with the app's Walkthrough Writing model; the chat beside the Reader plays it, one step a message: the writer first sets out the argument (three to seven claims in teaching order), then writes one chapter a claim, each ending on its claim as a recap card; ten to thirty steps, one point each — a figure step is about one panel, which the Reader scrolls to and outlines while the step reads it, and a panel is shown when it carries a claim, not because it is printed; an explain step marks a passage only when its point is in the source's own words — with open questions in four kinds (`recall`, `think_first`, `predict`, `find`) answered in the learner's own words or on the figure and graded against a reference answer, Say more chips, and small code-drawn animations for the steps whose mechanism a still figure cannot show. The first step situates the source in its field, as a journal's editorial summary would, and the last says what changes for the field if the authors are right. It explains the way a good textbook does, simply and step by step, for a newcomer to the field unless the learner's About you says otherwise: the terms the argument needs are taught in plain words before the steps that use them, an abstract claim starts from a concrete case, and the questions ask about the argument rather than its vocabulary. A paper or a chapter of a PDF book anchors steps to figures (outlined on the page) and passages; an article or an EPUB chapter is shown as text, so its steps anchor to passages alone, which the Reader scrolls to and flashes. Every anchor is checked against the source before saving; `warnings` names the ones dropped. Steps are shown before animations are drawn. Replaces the source's walkthrough. A book is walked one chapter at a time. Bills the learner's OpenRouter key; `animations: false` writes the steps alone. The result's `subject` (`paper`, `chapter`, `article`) and `figure_anchors` say what was walked and whether figures may be pointed at. A YouTube video is not walked here: `save_walkthrough` writes its steps. |
| `get_walkthrough` | `source_id` \| `animation` | Read a walkthrough as the deck deals it: title, author (`app` or `assistant`), `chapters` (id, title, claim, step_ids), `card_count`, and each step's kind, title, body, `beats`, `more`, `cites` (the works it cites, each with `in_library` and the library's `source_id` when it holds one), anchor, `figure_title`, `panel_caption` and `source_mention` for a figure step, `quiz` (`kind`, question, answer, key_points, `target_panel` for find) and whether it has an animation — inline, or by reference (`animation: {animation_id, title, step, conditions, url}`). `status` is `ok`, `none`, or `stale` when the source's text, or the animation's address, changed since it was written; `subject` and `figure_anchors` say what the walk is of and whether its steps may point at figures. A video's walk says `moment_anchors`, and each of its steps' anchors carries `at`, the moment of the talk (m:ss). Pass `animation` for an animation's walk. |
| `list_walkthroughs` | `notebook_id?` | List every walkthrough in the library — or with `notebook_id` only those of sources that Notebook holds, a team Notebook's copy of a source included — newest first — what a notebook's Studio lists for its sources: its source (`source_id`, `source_title`, `subject`), title, author, `generated_at`, `step_count`, `card_count` (one card a point, one a question), `quiz_count`, `figure_step_count`, `animation_count`, and `status` (`ok`, or `stale` once the source's text changed). Read-only. |
| `save_walkthrough` | `source_id` \| `animation`, `title`, `chapters` \| `steps` | Save a walkthrough you wrote for a paper, a book chapter, an article or a YouTube video, dealt as a deck of cards beside it (and on the phone) — the in-Reader form of a figure companion site. Read the source and its figures first, then teach its argument: `chapters`, one per claim (a title, the claim as one sentence the learner could say back — its recap card — and its steps), or a flat `steps` list. Explain it the way a good textbook does, for a newcomer unless the learner's About you (`account.about_you`) says otherwise: the terms the argument needs taught in plain words before the steps that use them, a concrete case before an abstraction, each card saying how it follows from the last, and questions about the argument rather than its vocabulary. One point a step, written as `beats` (one a card, each may name the panel it is about); `more` chips (`label`, `text`, `from_paper`) for context a newcomer may want and the argument can do without; `cites` for the works a step's point rests on (`title`, `authors`, `year`, `venue`, `kind`, `doi`, `url`, `source_id`), shown under its cards as a source card that opens the work or adds it, with a DOI or address only one the source prints or you opened; anchors as before (`figure_label` + `panel_label`, or a `passage` copied exactly). A `quiz` step is open, never multiple choice: `kind` is `recall` (default), `think_first` (before the evidence), `predict` (the panel is hidden until the learner answers) or `find` (`target_panel` names the panel the learner must pick on the figure), with `answer` and `key_points`. A video's step takes `at`, the moment of the talk it is about (`754` or `12:34`): the Reader seeks the video there and holds it paused while the step's cards are read. A video step that quotes the talk and has no `at` is placed where the talk says the quote. Every anchor is checked against the source; a step that fails keeps its words and is named in `warnings`. Replaces the source's walkthrough. |
| `delete_walkthrough` | `source_id` \| `animation` | Remove a paper's, a chapter's, an article's, a video's or a saved animation's walkthrough; the subject is untouched. Confirm first. |

## Images

Every picture made from a prompt — drawn by ForeverLM, or made in ChatGPT, Claude or another tool and saved here — is kept on the Mac with a short title and the prompt it was made from, both stored inside the file itself, and listed in the Studio of the notebook it was made in; a picture in no notebook shows where it is used. Iterating on a picture makes versions of one image: pass `revises`, and the Studio shows the image once, at its newest version. Browser screenshots are not listed. All six need the Mac open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `list_images` | `query?`, `limit?`, `notebook_id?` | List the kept images (with `notebook_id`, only those that live in that Notebook), most recently changed first, each once at its latest version: title, `image_id`, prompt, model, versions and their ids, file path, and its `foreverlm://image/generated/<id>` line for a ForeverLM chat or Page. `query` keeps images whose title or prompt holds every word. |
| `get_image` | `image`, `version?` | Show one image as a picture, with its title, prompt, model, date and versions. The latest version unless `version` names another. |
| `generate_image` | `prompt`, `title?`, `shape?`, `quality?`, `revises?`, `notebook_id?`, `approved_spend_usd?` | Draw a picture with the learner's image model (`images.model`, Settings → AI Models → Images: any image model OpenRouter's Image API serves, drawn through OpenRouter) and keep it; returns the picture. Paid by the learner's OpenRouter key: a picture you can make yourself is kept with `save_image` instead. `title` names a new picture in two to six words; a revision keeps the image's unless it passes one. `notebook_id` puts a new image in a Notebook; a revision keeps its image's. |
| `save_image` | `prompt`, `title?`, `image_base64` \| `local_path`, `model?`, `revises?`, `notebook_id?` | Keep a picture made elsewhere, with its prompt (required — a picture is never kept without one) and, for a new image, a short title. PNG and JPEG are kept as they are; any other format becomes a lossless PNG. `revises` makes it the next version of an image already kept. `notebook_id` puts a new image in a Notebook; a revision keeps its image's. |
| `rename_image` | `image`, `title` | Give an image a new title, as the learner renames it in the gallery. Every version takes it. |
| `delete_image` | `image`, `version?` | Move an image, or one version of it, to the Trash. Confirm first. |

## Courses

A course is a series of lectures, each with its video, readings and papers, and
quizzes along the way. It lives in no notebook: a notebook may follow it, and
then gains every source the course gains. A course's outline, quizzes and
readings are kept by the Mac app, so most of these need the Mac open and
connected.

| Tool | Parameters | Description |
|---|---|---|
| `list_courses` | `notebook_id?` | Every course with its `course_id`, title, lecture and source counts, and the notebooks that follow it; with `notebook_id`, only the courses that notebook follows. Call it before making a course or adding to one. |
| `get_course` | `course_id` | One course: its details, the notebooks that follow it, its lectures and their item ids, and the sources on its path. |
| `create_course` | `title`, `course_code?`, `institution?`, `instructors?`, `notebook_id?` | Make an empty course; a title already in use is refused. `notebook_id` makes that notebook follow it. |
| `update_course` | `course_id`, `title?`, `course_code?`, `institution?`, `instructors?`, `playlist_url?`, `notebook_id?`, `unlink_notebook_id?` | Change a course's details, or make a notebook follow it or stop following it. An empty string clears a field. |
| `delete_course` | `course_id` | Delete a course: its lectures and their links go, and its sources stay in the library, ungrouped. Not undoable; confirm first. |
| `import_youtube_playlist` | `url`, `course_id?`, `notebook_id?` | Import a YouTube playlist as a course, as pasting its link does: each video on its own numbered lecture, in playlist order, with its transcript. Importing it again adds only the missing videos. This is the one way to make a playlist a course: `add_source` refuses a playlist. |
| `import_teachable_course` | `url`, `course_id?`, `notebook_id?`, `approved_spend_usd?` | Import a Teachable course from any of its lecture links: every lecture with a video becomes a video source on its own lecture, its transcript made from its audio in the background, a few minutes a lecture. Needs the learner signed in to the school in ForeverLM's own browser. |
| `generate_course` | `topic`, `source_ids?`, `plan?`, `learner_notes?`, `module_count?`, `use_web?`, `quizzes?`, `notebook_id?`, `schedule_start?`, `days_per_module?`, `approved_spend_usd?` | Plan and write a course on a topic from the learner's library (and the web with `use_web`): modules over the sources found, with a lesson and an exercise sheet each. `schedule_start` places one module every `days_per_module` days under a Goal. Takes minutes on the learner's OpenRouter key; tell them first, and call it once. |
| `create_course_lecture` | `course_id` \| `course_name`, `title?`, `number?` | Add a numbered lecture to a course; the number is the next free one unless given. |
| `rename_course_lecture` | `lecture_id`, `title` | Rename a lecture. |
| `add_source_to_lecture` | `lecture_id`, `source_id`, `role?` | Attach any source to a lecture as a material; a paper goes through `add_paper_to_lecture`. |
| `add_paper_to_lecture` | `lecture_id`, `source_id`, `assigned_reading?` | Attach a paper to a lecture as assigned reading (a row of the course, quizzed with its lecture) or as a paper the lecture only cites (opened from the video's Papers menu). |
| `remove_course_lecture_item` | `item_id` | Take one material off a lecture. |
| `get_lecture_papers` | `lecture_id` | The papers on one lecture, with their bibliographic details and whether each can be read. |
| `find_lecture_papers` | `lecture_id`, `force?`, `approved_spend_usd?` | Find the papers a lecture's video, transcript, notes, slides and other material cite, each kept as a candidate (`pending`, `imported`, `unresolved` or `dismissed`). Nothing is added: the learner picks. |
| `ingest_lecture_papers` | `lecture_id`, `cited_paper_ids`, `assigned_reading_ids?`, `approved_spend_usd?` | Add the candidates the learner chose and attach them to the lecture as papers it cites, or as assigned reading for the ids also in `assigned_reading_ids`. |
| `add_textbook_to_course` | `course_id`, `book`, `course_focus?`, `learner_background?`, `approved_spend_usd?` | Plan a textbook from the library into a course: for each lecture, the sections this learner should read with it and why, chosen by your Textbook Readings model. Calling it again replaces that book's readings. |
| `save_course_textbook_readings` | `course_id`, `book`, `readings` | Save textbook readings you chose yourself: each one's lecture, chapter, optional pages, title and reason. Replaces only that book's readings and costs nothing. |
| `generate_course_quizzes` | `course_id`, `quiz_ids?`, `rewrite?`, `checkpoint_every?`, `final_test?`, `draw_pictures?`, `confirm_drawings?`, `approved_spend_usd?` | Write a course's quizzes ahead, the way a Khan Academy unit does: a practice quiz after each lecture, a checkpoint where a topic ends, and a test at the end, asking about every key point of the lectures and their readings, in open recall, never multiple choice. Only missing quizzes are written, so calling again resumes. New drawings stay off until you agree to their price. |
| `save_course_quiz` | `course_id`, `kind`, `learning_points`, `questions`, `lecture_ids?`, `after_lecture_id?`, `quiz_id?`, `title?`, `symbol?` | Save a quiz you wrote (`practice`, `checkpoint` or `test`), or replace one. List every learning point of its lectures and readings first; each needs a question and each question a quote from its source, and a quiz that leaves a point untested is refused. |
| `get_course_quiz` | `quiz_id`, `include_answers?` | One quiz: its kind, its lectures, the learner's latest score, and its questions with their sources and pictures. Answers only with `include_answers`, so the learner can be quizzed one question at a time. |
| `record_course_quiz_result` | `quiz_id`, `results`, `sitting_id?`, `new_sitting?`, `finish?` | Record graded answers as the quiz goes, into the sitting the app's **Continue Quiz** picks up. Every miss becomes a Memory item; the sitting completes when every question has an outcome, or with `finish`. |
| `rename_course_quiz` | `quiz_id`, `title`, `symbol?` | Name a quiz after the topics it covers, two to six words, without the word "Quiz". |
| `delete_course_quiz` | `quiz_id` | Remove a quiz from its course; the learner's latest score is kept. |
| `set_course_quiz_picture` | `quiz_id`, `question_id`, `picture?`, `remove?` | Pin a picture to one question, replace it, or take it away: a lecture frame or reading page from `show_source_image`, an image kept in ForeverLM (`generate_image`, `save_image`), or a brief for ForeverLM to draw later. It shows with the question or waits for the answer. |
| `add_course_quiz_pictures` | `course_id`, `quiz_ids?`, `capture_slides?`, `choose?`, `draw?`, `replace?`, `confirm_drawings?`, `approved_spend_usd?` | Give quizzes already written the lecture slides or reading figures that make their points clear, without rewriting a question. Drawing new pictures (`draw`) is off by default and waits for your agreement to its price. |

## Schedule

Read the current Schedule before proposing or changing a plan. Dates use
`YYYY-MM-DD` in the learner's local calendar.

| Tool | Parameters | Description |
|---|---|---|
| `get_schedule` | `goal_id?`, `include_completed?` | Return the current Schedule week, placements, completion state, and the Goals and Notebooks each placement serves. |
| `get_today_sources` | `goal_id?`, `date?`, `date_basis?`, `activity_kind?`, `include_completed?`, `max_chars_per_source?` | Return readable content for sources planned, used, or completed on a chosen day. |
| `assign_sources_to_day` | `source_ids`, `date`, `goal_id?` | Assign or move sources to a calendar day. With `goal_id` (a Goal or a Notebook) the sources join it; without it, placed sources move and unplaced ones go on the Schedule untagged. |
| `unschedule_sources` | `source_ids`, `goal_id?` | Take sources off the Schedule, or with `goal_id` untag them from that Goal or Notebook only. Activity history is kept. |
| `clear_schedule_day` | `date`, `goal_id?`, `include_completed?` | Remove matching placements from one day. |
| `mark_schedule_day_done` | `date`, `goal_id?` | Mark every pending source on one day complete. |
| `set_source_completion` | `source_id`, `is_completed`, `goal_id?` | Complete or reopen one scheduled source. |
| `forget_source_activity` | `source_ids`, `date` | Take back activity ForeverLM recorded on sources that did not happen, such as a review marked by a chat that reviewed nothing: each source's automatic Schedule entry and its activity days, the read stamp that day set, and any assignment the entry's completion closed, on every device. Refused for a planned source (use `unschedule_sources` or `set_source_completion`) and for one with activity on another day. Not undoable; needs an active Mac. |

## Ideas

An Idea is the learner's own jotted-down thought: a sentence with no deadline
and no commitment, optionally a note, and links to what it draws on and what it
produced. It is not a Goal — a Goal has a deadline and paces sources toward it.
When an Idea earns a date, create the Goal with `create_learning_goal` and then
`link_idea` with kind `goal`, so the Idea records what it became.

A link may only name a record this library holds, and the id is checked against
the kind's own table before anything is written. The five kinds are `source`,
`artifact` (a Page, Site or animation), `chat`, `goal` and `notebook`.

These tools need the learner's Mac open and connected: an Idea is a row in the
app's own store and its chips resolve against that library.

| Tool | Parameters | Description |
|---|---|---|
| `list_ideas` | `include_archived?`, `notebook_id?` | List the learner's Ideas, newest first, each link resolved to the title of what it points at; with `notebook_id`, only those linked to that Notebook or one of its Goals. |
| `create_idea` | `title`, `notes?`, `links?` | Jot an Idea down in the learner's own words, optionally already linked. |
| `update_idea` | `idea_id`, `title?`, `notes?`, `status?` | Reword an Idea, write or clear its note, archive it or bring it back. |
| `link_idea` | `idea_id`, `kind`, `target_ids` | Link research or an exploration to an Idea. Repeats are skipped and reported. |
| `unlink_idea` | `idea_id`, `kind`, `target_ids` | Take a link off an Idea. What it pointed at is untouched. |
| `delete_idea` | `idea_id` | Permanently forget one Idea. Its links go; everything they named stays. |

## Directions

A Direction is something the learner could pursue next toward a Goal, notebook
or Idea, found by research: a specific approach aimed at a specific
population, system or problem, with the papers or pages it rests on, the
strongest case against it, and the cheapest test. It is ForeverLM's proposal
until the learner pursues it or sets it aside with a reason, and the next
search reads those answers first.

A search is yours to run: `find_directions` returns the brief and the steps,
you research on your own allowance (`search_literature` is free), and
`propose_directions` saves what survived. Nothing is added to the library;
each piece of evidence has Add to Library in the app.

These tools need the learner's Mac open and connected: a Direction is a row in
the app's own store toward a Goal, notebook or Idea there.

| Tool | Parameters | Description |
|---|---|---|
| `find_directions` | `home_id`, `focus?` | The brief for a direction search: the home, its instructions and sources, related library sources, the learner's Ideas and chats, every direction already answered, and the steps. Makes no model call. |
| `search_literature` | `query`, `from_year?`, `to_year?`, `preprints_only?`, `sort?`, `limit?` | Search PubMed for free, in PubMed syntax (`[tiab]`, `[au]`, `review[pt]`). Each work gives its abstract, DOI, free full text when PubMed Central has it, and whether the library already has it. |
| `propose_directions` | `home_id`, `directions`, `session_id?` | Save the three to seven directions a search kept. Each needs its sentence, why it is worth a look, its angle and evidence with a DOI or address; one the home already has is skipped. |
| `list_directions` | `home_id?`, `status?` | Directions with their evidence and the learner's answers: pursued, then proposed, then set aside. |
| `update_direction` | `direction_id`, `status?`, `reason?`, `title?`, `rationale?`, `objection?`, `next_step?`, `add_evidence?` | Record the learner's answer with their reason, or change a direction after a deeper look. |
| `delete_direction` | `direction_id` | Permanently forget one direction. Set it aside instead to keep it from being proposed again. |

## Canvas

The Canvas is a zoomable plane where the learner thinks: the Ideas and other
cards they placed, the regions they drew around them, and the arrows between
them. A learner may have several canvases in their Space; the reading and edit
tools act on the one open on the Mac. Cards are named by `item_id`:
`source:<id>`, `doc:<id>`, `idea:<id>`, `page:<source_id>:<n>` for one page of
a PDF, `canvas:<id>`, `chat:<session_id>` and `picture:<image_id>`.

An assistant edits the Canvas only on the learner's word; to suggest an
arrangement it shows a lens or asks the Canvas. Each edit is one of theirs,
which Undo (⌘Z, or `undo_canvas`) takes back. Every Canvas tool needs the Mac
open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `list_canvases` | `notebook_id?`, `include_trash?` | The learner's canvases, listed under Canvases in the Space: each one's `canvas_id`, name, dates, space, pin, Trash mark, notebook, and which one is open on the Mac. |
| `open_canvas` | `canvas_id` | Open a canvas on the Mac, beside the chat; the tools below then act on it. |
| `create_canvas` | `name?`, `space_id?`, `notebook_id?`, `frame_notebook?`, `open?` | Make a canvas, filed in a space or a notebook, and open it. `frame_notebook` draws the notebook's sources on it in a frame; otherwise it starts empty. |
| `update_canvas` | `canvas_id`, `name?`, `space_id?`, `notebook_id?`, `pinned?`, `in_trash?` | Rename a canvas, file it in a space or a notebook (`""` takes it out), pin it in the Space sidebar, or move it to Trash and back. Nothing on it moves. |
| `delete_canvas` | `canvas_id` | Delete a canvas already in Trash forever, with what is placed on it, on every device. The sources, Pages and Ideas that were on it are untouched. Not undoable. |
| `get_knowledge_map` | `include_unplaced?`, `limit?` | Read the open canvas: its regions and the cards in each, the cards outside any region, each Idea's evidence, the arrows with their labels and `edge_id`, what is in view, what the learner selected or circled, the lens showing, and each card's `item_id` and rect. Call it before answering about the canvas. |
| `get_canvas_memory` | `item_ids?` | How the learner's kept Memory cards stand behind each card and region on the canvas (due, fading, solid, dusty), and the arrows `make_cards_from_canvas` can draft from. |
| `apply_map_lens` | `title`, `layout`, `groups?`, `x_axis?`, `y_axis?`, `points?`, `concepts?`, `links?`, `hide_others?` | Show a lens: the cards you name laid out in labelled groups, on two axes, or beside the concepts of a topic in the order they connect, and the rest faded. Nothing the learner placed moves and nothing is saved; the banner offers **Keep** and **Back to My Canvas**. |
| `keep_map_lens` | — | Keep the lens, on the learner's word, as the banner's **Keep** does: its cards are placed and its groups or concepts become regions. |
| `clear_map_lens` | — | Take the lens off; nothing it showed is kept. |
| `focus_map` | `item_ids?`, `region?`, `select?` | Fly the canvas to cards or a region and ring or select them. Moves the view only. |
| `build_canvas` | `canvas_id?`, `notes?`, `groups?`, `ungrouped?`, `arrows?`, `trees?`, `pdf_pages?`, `talks?`, `annotations?` | Lay a whole picture out in one call: note cards (each an Idea of the learner's, or a passage card quoting a source), library cards in labelled regions, arrows, mind maps (`trees`), a PDF's pages as cards (`pdf_pages`), a talk's slides as a storyboard with the papers each cites under it (`talks`), and the learner's reason under a card (`annotations`). Nothing already placed moves. |
| `place_on_canvas` | `item_ids`, `region?`, `beside?`, `new_region?`, `color?`, `folded?`, `w?`, `h?`, `face?`, `annotations?` | Set cards down, or move ones already placed: into a region or a notebook's frame, beside a card, in a new region, or in free space in view. A paper whose PDF is on the Mac is set down as its first page. |
| `take_off_canvas` | `item_ids` | **Take Off Canvas**: each card waits in the canvas's Library again, and its arrows go with it. Nothing is deleted. |
| `arrange_on_canvas` | `item_ids`, `arrangement?`, `align?` | **Tidy Up** (a row, a column or a grid) and **Align** for cards on the canvas. |
| `update_canvas_card` | `item_ids`, `color?`, `folded?`, `w?`, `h?`, `fit_to_content?`, `page?`, `annotation?`, `plain?`, `answered?` | Change how cards look: tint, fold, size, a source shown as a page of its PDF, the learner's words under a card, an Idea drawn as plain words, a question marked answered. |
| `create_canvas_region` | `name?`, `item_ids?`, `color?`, `locked?`, `notebook_id?` | Draw a region around cards or in free space; with `notebook_id`, that notebook's frame. |
| `update_canvas_region` | `region`, `name?`, `color?`, `x?`, `y?`, `w?`, `h?`, `notebook_id?`, `collapsed?`, `locked?`, `layout?`, `fit_to_content?`, `grow_to_hold?` | Rename, recolour, move, resize, fold up or lock a region, link it to a notebook as its frame, lay it out as a mind map (`layout: tree`), or fit it to what it holds. |
| `delete_canvas_region` | `region`, `take_cards_off?` | Delete a region; its cards and the regions inside it stay unless `take_cards_off`. |
| `draw_canvas_arrow` | `from`, `to`, `label?`, `stance?`, `route?`, `dashed?`, `heads?`, `color?`, `tree?` | Draw an arrow between two cards (an end may be a region) with a short label. `stance: supports` draws it green and `contradicts` red; `tree` makes it a mind-map branch. |
| `update_canvas_arrow` | `edge_id?`, `from?`, `to?`, `label?`, `stance?`, `route?`, `dashed?`, `heads?`, `color?`, `tree?` | Change an arrow, named by its `edge_id` or its ends. |
| `delete_canvas_arrow` | `edge_id?`, `from?`, `to?` | Delete an arrow; the cards stay. |
| `undo_canvas` | `redo?` | Undo the learner's last canvas edit on this Mac, or redo. |
| `ask_canvas` | `tool`, `item_ids`, `approved_spend_usd?` | The inspector's **Ask**: `bridge` finds library sources that connect the cards, `connect` proposes typed arrows between them, `gaps` names questions they leave open. Proposals are drawn dotted, and only the learner's ✓ or **Keep All** keeps one. |
| `make_cards_from_canvas` | `item_ids`, `edge_ids?`, `approved_spend_usd?` | The Canvas's **Make Cards**: Memory cards from the learner's Ideas and arrows, each standing on a passage quoted from the sources behind it, waiting in To Check. |
| `set_canvas_display` | `memory_layer?`, `written_faces?`, `view_captions?` | The canvas's display switches on this Mac. `view_captions` calls your Canvas Summaries model each time the learner pauses, so it is turned on only when asked. |
| `lint_canvas` | `limit?` | Check the layout for overlapping cards, cards crossing a region's edge, arrows across cards, and empty regions. Changes nothing. |
| `screenshot_canvas` | `item_ids?`, `scale?` | A PNG of the canvas as it is drawn, saved under Exports/ in the library folder and attached when small enough. |
| `list_canvas_versions` | `canvas_id?` | A canvas's versions kept on this Mac, newest first: those the learner saved with **Save Version…** and those kept on their own after a burst of edits, at most 30. |
| `save_canvas_version` | `canvas_id?`, `name?` | Keep the canvas as it is now as a named version. |
| `restore_canvas_version` | `version_id`, `canvas_id?` | Put a version back, as one edit Undo takes back; what the canvas held is kept as a version first. |

## Atlases and reading levels

An Atlas lays a topic out at several levels: 8 to 24 concepts in a small
hierarchy, each with a gist, a one-sentence line, the terms a newcomer needs,
how it relates to the others, whether it is established, debated or
speculative, and the passages in the learner's library that bear on it. It
opens in the Studio's Atlas pane. Reading levels are one source zoomed out, as
the Levels panel beside the Reader shows it. These need the Mac open and
connected.

| Tool | Parameters | Description |
|---|---|---|
| `make_atlas` | `topic?`, `item_ids?`, `notebook_id?`, `rebuild?`, `approved_spend_usd?` | Make an Atlas over Canvas cards, a notebook or the whole library, with one call to your Atlas model. An Atlas of the same topic and scope opens as it is unless `rebuild`. |
| `list_atlases` | `limit?` | The Atlases, latest first, with their topic, scope and concept count. |
| `get_atlas` | `atlas_id`, `concept_id?`, `deepen?`, `approved_spend_usd?` | Read an Atlas, or one concept with its passages; `deepen` first writes the concept in depth (one model call, saved with the Atlas). |
| `delete_atlas` | `atlas_id` | Delete an Atlas; cards drafted from it stay. |
| `get_source_levels` | `source_id`, `level?`, `write_if_missing?`, `approved_spend_usd?` | A source zoomed out: its gist, why it matters, its key findings, a line for each section and each paragraph, and its key terms, each anchored to the source's own first words there. `write_if_missing` writes them on your Reading Levels model when none fit the current text; otherwise nothing is spent. |

## Skills

A skill is instructions the learner wrote for one kind of work, in the shape of
a `SKILL.md`: a name, a description that says when it applies, and markdown
instructions. ForeverLM's chat lists every skill's name and description in its
system prompt, reads a skill with `get_skill` when a request matches it, and
takes `/name` in the composer to call one directly. An assistant beside the app
can use the same skills: read one with `get_skill` before doing the work it
describes.

These tools need the learner's Mac open and connected: a skill is a row in the
app's own store. The learner writes the same rows under **Plugins › Skills** in
the Mac app; these tools are how an assistant writes them.

| Tool | Parameters | Description |
|---|---|---|
| `list_skills` | — | List the learner's skills: id, name and description. |
| `get_skill` | `name?`, `skill_id?` | Read one skill in full, with the same skill as a `SKILL.md`. |
| `save_skill` | `skill_id?`, `name?`, `description?`, `instructions?`, `skill_markdown?` | Create a skill, or change the fields passed on one. A whole `SKILL.md` can stand in for the three fields. |
| `delete_skill` | `skill_id` | Permanently delete one skill. Chats that already used it keep what they were told. |

## Working notes

ForeverLM keeps short notes about how the learner is working: a thread of work
in progress, an interest, a preference, a fact about their situation, an
outcome. The learner adds them, or asks ForeverLM to keep one, and the nearest
few ride into every ForeverLM chat. They are kept in the background, as a
memory, never as pages: Settings › Data & Privacy › Notes about your work
reads, corrects and forgets the notes. An assistant beside the app can read them to know
what the learner has been doing, and writes or forgets one only when the
learner asks.

These tools need the learner's Mac open and connected: the notes are a file in
the app's own store.

| Tool | Parameters | Description |
|---|---|---|
| `list_working_notes` | `query?`, `kind?`, `limit?` | The notes with their ids, kinds, sentences and dates, and the running summary. With a query, the nearest notes first. |
| `save_working_note` | `text`, `kind?`, `source_ids?` | Write one note the learner asked for. A sentence that is already a note is not written twice. |
| `update_working_note` | `note_id`, `text?`, `kind?` | Correct a note's sentence or kind. |
| `forget_working_note` | `note_id` | Forget one note, on every Mac. |

## Reading views

A reading view changes how one web article reads, in the learner's own words —
"remove the inline citations", "hide the subscribe bar" — without changing the
article. A model reads the article and names exact pieces of its text to hide;
the Reader hides them on the page, and the learner can switch back to the
original at any time. The article's saved page, its text, highlights, chat and
search are untouched.

These tools need the learner's Mac open and connected: the reading view is a
file on that Mac, drawn by its Reader, and the model that names what to hide
runs from there. It does not sync to other devices.

| Tool | Parameters | Description |
|---|---|---|
| `make_article_reading_view` | `source_id`, `instruction`, `approved_spend_usd?` | Make the article's reading view from the learner's words, replacing an earlier one. If nothing matches, nothing is saved. Answers with how many pieces are hidden and examples. |
| `get_article_reading_view` | `source_id` | Whether the article has a reading view, its instruction, whether the Reader shows it, how many pieces it hides, and the first pieces. |
| `set_article_reading_view_shown` | `source_id`, `shown` | Switch the Reader between the reading view and the original. The view is kept either way. |
| `clear_article_reading_view` | `source_id` | Delete the reading view, so the Reader shows the original. |

## Adding material to the library

Readable web material runs through the ForeverLM app's own importer, so a source
has exactly one path into the library and its identity, deduplication, and
derived data stay consistent. `add_source` therefore needs the learner's Mac to
be open and connected; called without one, it answers with an explanation rather
than filing an empty source.

An EPUB travels differently because its original container matters. `import_epub`
uploads the untouched bytes into the learner's private iCloud as the same queued
Web Import record Studio already writes. A signed-in Mac then runs Add Book's
native importer over that asset, preserving chapters, readable text, cover art,
and embedded images. The MCP call accepts up to 15 MB and returns the temporary
handoff source ID; after expansion, `list_sources` reports the final book ID and
chapter source IDs under the matched title.

| Tool | Parameters | Description |
|---|---|---|
| `add_source` | `url`, `title`, `source_type`, `content?`, `author?`, `parent_group?`, `occurred_at?`, `notebook_id?` | File a non-paper source written by someone else, with its full text when you have already read it. The text is shown verbatim, not rendered as Markdown; assistant-written material belongs in `create_doc`. A podcast episode is `source_type` `podcast`, and a link on a podcast host such as podcasts.apple.com is filed as one whatever the type says: its text is the episode's transcript, which the app finds on Apple Podcasts, so `content` passed for it is not kept and `find_podcast_match` with `resolve_podcast_match` confirms the episode. A meeting (`source_type` `meeting`) takes its series as `parent_group` and when it took place as `occurred_at`. Repeated calls with the same URL deduplicate. `notebook_id` files the source in that Notebook as well, or files the source already at that URL; the answer's last line, `notebook_id_applied`, says whether it is in the Notebook. |
| `import_epub` | `filename`, `content_base64`, `title?` | Upload an original EPUB for native book expansion without flattening its text or discarding images. Accepts complete base64-encoded EPUB bytes up to 15 MB. |
| `add_sources` | `sources`, `notebook_id?` | Add up to 50 sources in one call, each with `add_source`'s fields plus `update_existing`. An address already in the library is reported per item instead of failing the batch, and `update_existing` refreshes that source's text, title and author (and a meeting's date and series). Built for plugins pushing a feed: use stable canonical URLs, and keep a call under about 1 MB. `notebook_id` files every item in that notebook as well. |
| `import_paper_from_url` | `url`, `source_url?`, `title?`, `notebook_id?`, `approved_spend_usd?` | Download a paper's PDF from a DOI, an arXiv or OpenReview page, a publisher's page or a direct link, extract its text, and add it as a paper, saved at once with its PDF. Its metadata is read and its text cleaned in the background, so the answer comes once the PDF is in, with the paper's id and a `work_id`; several imports can be sent together and their reading waits its turn. A failure is saved on the paper, which keeps its PDF. When the publisher blocks the PDF the paper is still added, marked paywalled, with its bibliography, ready for `attach_pdf_to_paper` or `recheck_paywalled_papers`; only a network error or a 404 adds nothing. `notebook_id` files it in a notebook (or a Goal) too, and a paper the library already holds joins it instead. |
| `import_local_pdf_as_paper` | `file_path`, `title?`, `approved_spend_usd?` | Import a PDF on the Mac as a new paper: copied into the synced Papers folder, its text extracted, and saved at once with its PDF. Its metadata is read and its text cleaned in the background, so the answer comes in seconds with the paper's id and a `work_id`; several imports can be sent together and wait their turn. A failure is saved on the paper, which keeps its PDF. To give an existing paper its PDF, use `attach_pdf_to_paper`. |
| `import_local_file` | `file_path`, `kind?`, `title?`, `approved_spend_usd?` | Import any file on the Mac the way the app does: a PDF as a paper or a book, an EPUB or DRM-free Kindle file as a book, a text or Markdown file as a text source. A paper is read in the background as `import_local_pdf_as_paper` reads it, and a book goes through Add Book's importer (title and author read, split into chapters, each chapter filed under the book) in the background, so the answer comes at once with a `work_id`; `list_sources` with `source_type` `book` lists the chapters when it is done. `kind` `auto` (the default) takes a PDF of 100 pages or more for a book; pass `paper` or `book` to choose. The file must be in the ForeverLM library or the Desktop, Documents or Downloads folder. |
| `import_gemini_notebook` | `url`, `notebook_id?` | Import a Gemini Notebook (NotebookLM until July 2026) from its `notebook.google.com` address, as pasting the link does: each source through its ordinary route, each chat as a chat under the notebook, each note and report as a Page. Audio and video overviews, flashcards, quizzes, mind maps and apps stay in Gemini (`left_in_notebook`). Importing again adds only what is new. Needs the learner signed in to Google in ForeverLM's own browser. |
| `import_video_overview` | `file_path`, `notebook_id?` | Bring a video overview (a Gemini Notebook MP4, or any MP4, M4V or MOV on the Mac) into a notebook as a video source its Studio lists as a Video overview. The file must be in the ForeverLM library or the Desktop, Documents or Downloads folder. Nothing is spent, and the video has no transcript. |
| `fetch_video_transcript` | `source_id`, `passcode?`, `approved_spend_usd?` | Fetch and store the transcript of a YouTube video, a one-off Zoom cloud recording link, or a Teachable lecture. A passcode-protected Zoom recording asks for its `passcode`, which is then kept in the Keychain; a Teachable lecture is transcribed from its audio in the background and needs the learner signed in to the school inside ForeverLM. |
| `follow_youtube_foreverlm_playlist` | `account?` | Make one connected YouTube account's playlist named "ForeverLM" its import source and import its videos (their details; transcripts come when needed). `account` is its channel title or id; optional when only one account is connected, and an error lists them when several are. Needs YouTube connected in Plugins › YouTube. |
| `follow_youtube_liked_videos` | `account?`, `import_existing?`, `format_transcripts_automatically?` | Make one connected YouTube account's Liked videos its import source and keep them fresh in the background, with or without the likes already there. `account` is as for `follow_youtube_foreverlm_playlist`. AI formatting of the transcripts is off unless asked for, because a large history can run up a bill on the learner's OpenRouter key. |
| `refresh_youtube_sources` | `account?` | Check every connected YouTube account's playlist or likes now, or one account's when `account` is given, and import new videos (their details only). |
| `set_connector_auto_import` | `connector`, `enabled` | Turn the YouTube plugin's automatic import on or off. |

## Managing sources

Changing, hiding and removing what is already in the library.

| Tool | Parameters | Description |
|---|---|---|
| `update_source` | `source_id`, `title?`, `author?`, `source_type?`, `journal?`, `published_year?`, `doi?`, `parent_group?`, `content?`, `is_paywalled?` | Change a source's details: title, author, type, a paper's venue, year and DOI, the course, book or series it is filed under, its text, or its paywall mark. |
| `move_source_type` | `source_id`, `new_type` | Reclassify a source, such as an article that is really a paper. |
| `set_source_read` | `source_id`, `read?` | The Reader's **Mark as Read** for a web article, paper or video (Mark as Watched for a video); other types are refused. Unread clears the stamp, and a video's watch progress with it. The Schedule's completion is separate (`set_source_completion`). |
| `set_source_hidden` | `source_id`, `hidden` | Hide a source from the Studio's lists, or show it again. Hiding is visual only: the source stays in chat, search and reviews. |
| `set_source_paywall_status` | `source_id`, `is_paywalled` | Mark an article, paper or unclassified source paywalled, or clear the mark, so the app stops retrying it and offers the paywall recovery options. |
| `list_source_actions` | `source_id` | What can be done to a source, matching its row's menu; actions that need the screen, such as showing it in Finder, are reported as unavailable here. |
| `refetch_source_content` | `source_id` | Fetch a source's text again from its address and clear an error. An article is refreshed as **Refresh from Website** does it, and kept only when the site returned at least as much text as the saved copy, so a paywall preview never replaces it; a podcast episode's transcript is fetched from Apple Podcasts again, in the background. |
| `fetch_source_from_archive` | `source_id` | Fetch a paywalled or failed web article's text from archive.ph and store it. |
| `attach_pdf_to_paper` | `source_id`, `file_path?`, `pdf_url?` | Give a paper its PDF, from a file on the Mac or a URL (a Slack file's `download_url` works): copied into the synced Papers folder, its text extracted and its metadata read, paywall and error state cleared. |
| `attach_text_file_to_source` | `source_id`, `file_path` | Attach a text, Markdown or HTML file on the Mac to an article, copied into the synced Articles folder with its text stored. |
| `extract_paper_metadata` | `source_id`, `approved_spend_usd?` | Read a paper's author, journal, year and DOI again with AI. |
| `extract_article_metadata` | `source_id`, `approved_spend_usd?` | Read an article's title and author again with AI. |
| `download_papers_needing_attention` | `limit?`, `source_ids?`, `approved_spend_usd?` | The Studio's **Try Papers Needing Attention**: find the PDF of each paper that has a landing page, no PDF and no paywall mark, directly or from an open-access copy. A paywall-shaped failure is marked paywalled; a passing one is left as it was and reported. Call again to go past `limit`. |
| `recheck_paywalled_papers` | `limit?`, `source_ids?`, `approved_spend_usd?` | Look again for a legitimate free PDF of papers marked paywalled: the publisher, PubMed Central, Unpaywall, Crossref, OpenAlex and preprint servers. A recovered PDF goes through the normal paper pipeline and clears the mark. |
| `find_duplicate_papers` | `archive_duplicates?` | Find duplicate papers across the library with AI; `archive_duplicates` archives the weaker copy in each group. |
| `save_source_review_guide` | `source_id`, `guide`, `content_sha256` | Save a review guide you wrote for one source (its key ideas, review questions with strong answers and probes, and a connection question), bound to the text revision `get_source_content` returned. It replaces an older guide and syncs. |
| `clear_source_derived_data` | `source_id` | Throw away a source's stored text and embeddings without archiving it; getting them back costs another fetch. |
| `archive_source` | `source_id` | Archive a source: the record stays, and its stored text, embeddings and Schedule placements go. |
| `unarchive_source` | `source_id` | Bring an archived source back, which also undoes `remove_source`; a source backed by a file on the Mac has its text rebuilt. Schedule placements are not restored. |
| `remove_source` | `source_id` | Remove a source as the Studio row's menu does: its address is dismissed so nothing adds it again, then it is archived (a paper never downloaded is deleted). |
| `delete_source` | `source_id` | Delete a source for good. The row's ordinary Remove is `remove_source`. |
| `rename_group` | `group_type`, `group_key`, `new_title` | Rename a course, video playlist or meeting series. |
| `set_group_hidden` | `group_type`, `group_key`, `hidden` | Hide a course, video playlist or meeting series from the Studio's lists, or show it again; its sources stay in chat, search and reviews. |

## Podcasts and YouTube

A podcast episode's transcript comes from Apple Podcasts. These tools match
episodes, find a transcript on YouTube when Apple has none, and decide which
shows and channels are seen. A muted show or channel leaves the lists and is
left out of chat, search, reviews and the library tools, except an episode or
video shown on its own.

| Tool | Parameters | Description |
|---|---|---|
| `find_podcast_match` | `source_id` | Look for the Apple Podcasts episode that matches a source, by its YouTube link or title, and stage the match for confirmation. |
| `resolve_podcast_match` | `source_id`, `confirm` | Confirm a staged match, which makes the source that podcast episode, or reject it. |
| `find_podcast_on_youtube` | `source_id`, `always_for_show?`, `approved_spend_usd?` | The Reader's **Find on YouTube**, for an episode whose transcript Apple does not give: candidates from the episode's own page, the show's YouTube channel and YouTube search, best first, with nothing attached. `always_for_show` ticks "Always find … on YouTube" for the show. Needs YouTube connected in Plugins › YouTube. |
| `import_podcast_youtube_transcript` | `source_id`, `video`, `replace?`, `approved_spend_usd?` | The Reader's **Use Transcript**: the captions of a video the learner confirmed is this episode become its transcript, then are formatted and cleared of ad reads in the background. Refused for an episode that has a transcript unless `replace`. |
| `remove_all_from_podcast` | `show_name` | **Remove All from …**: dismiss and archive every episode of the show. |
| `set_podcast_show_import_blocked` | `show_name`, `blocked` | **Never Import …**: its episodes are never imported again, however often they are played. Episodes already in the library stay. |
| `set_podcast_show_hidden` | `show_name`, `hidden` | Mute a show, or bring it back. |
| `set_podcast_episode_hidden` | `source_id`, `hidden` | Hide one episode from the lists (visual only: it stays in chat, search and reviews), or show it. |
| `set_podcast_episode_visible_override` | `source_id`, `visible` | Show one episode of a muted show, or stop showing it. |
| `set_youtube_channel_hidden` | `channel_name`, `hidden` | Mute every video from one YouTube channel, or bring them back. |
| `set_youtube_video_visible_override` | `source_id`, `visible` | Show one video of a muted channel, or stop showing it. |

## What a source cites

A video's slides, a meeting's talk, a paper's reference list and an article's
links all name other work. These tools read them and keep each find as a
candidate: `pending` (can be added), `unresolved` (seen, but no record
matched), `imported`, or `dismissed`. Nothing is added until the learner picks
it.

| Tool | Parameters | Description |
|---|---|---|
| `extract_video_slides` | `source_id` | Capture a video's slide frames so they can be shown and read; slides are not captured on import. No model call. |
| `scan_video_for_cited_papers` | `source_id`, `force?`, `all_slides?`, `approved_spend_usd?` | Read a video's distinct captured slides for the papers they cite, capturing the slides first when needed. Independent slides are read concurrently. The default pass reads at most 40 and reports how many were skipped; `all_slides` reads the complete deck. A video already scanned is not scanned again unless `force`, which keeps every earlier decision. |
| `scan_meeting_for_mentioned_papers` | `source_id`, `force?`, `approved_spend_usd?` | Read a meeting's whole transcript and notes for papers someone named, transcribing a recording-only meeting on the Mac first. |
| `scan_article_for_linked_sources` | `source_id`, `force?`, `approved_spend_usd?` | Read a web article's saved page for the sources its links point at (articles, papers, videos, podcast episodes), each with a line on what the article says about it. The links are read off the page; a model only judges which of them are sources. |
| `list_video_cited_papers` | `source_id` | The candidates found for a source, each with its kind, address and status. |
| `import_video_cited_paper` | `cited_paper_id`, `approved_spend_usd?` | Add one candidate to the library by the route its kind takes: a paper with its PDF, a video with its transcript, an article with its page. |
| `update_video_cited_paper_status` | `cited_paper_id`, `status` | Dismiss a candidate, or put a dismissed one back (`pending`). |
| `get_paper_references` | `source_id`, `include_reference_text?`, `only_unlinked?` | A paper's stored reference list: each entry's number, text, the DOI or address it names, how the link was found, and the library source that is that paper when you hold it. `include_reference_text` also returns the PDF's reference-list text, the one way to read a paper's references through ForeverLM. Read-only; Mac only. |
| `resolve_paper_references` | `source_id`, `force?` | Read a paper's reference list from its PDF and find each entry's link, free and with no model: a printed DOI or address, or a Crossref or OpenAlex record the entry prints. Runs by itself when a paper is added; call it for an older paper or after a catalog was down. Mac only. |
| `save_paper_references` | `source_id`, `references`, `replace?` | Save entries you authored for a paper: each with its citation `number`, its `text` when new, and the `doi` or `url` you read in it or found yourself (never one recalled), plus optional `title`, `authors`, `journal`, `year`, `label`. Costs none of your AI budget. Saved in one step or not at all. Mac only. |

## Plugins you build

A [plugin you build yourself](/build-your-own-plugin) connects with the
`mcp:ingest` permission, which allows only `add_source`, `add_sources`,
`update_source_content`, `get_connector_inbox`, `import_connector_paper`,
`report_connector_status` and `get_mcp_status`. `remove_connector_sources` is
for a full-access assistant.

| Tool | Parameters | Description |
|---|---|---|
| `get_connector_inbox` | — | The plugin's own staging folder on the Mac for paper PDFs: write a downloaded PDF there, then pass its path to `import_connector_paper`. It is the only local path an ingest-only plugin may hand over. |
| `import_connector_paper` | `url?`, `source_url?`, `file_path?`, `title?`, `approved_spend_usd?` | Import one paper through the whole paper pipeline, from a public paper URL or DOI, or a PDF staged in the inbox. Deduplicated by canonical URL and DOI, run through Paper Metadata and Source Content Cleanup, and labelled with the plugin's name. |
| `report_connector_status` | `state`, `detail?` | The plugin's sync health (`healthy`, `syncing`, `needs_reconnect` or `error`), shown with it in Plugins: call it at the start and end of every run, and say `needs_reconnect` when the service's authorization is no longer valid. |
| `update_source_content` | `content`, `source_id?`, `url?`, `title?`, `author?` | Replace a source's stored text (and optionally its title and author), found by `source_id` or canonical `url`. Reviews and Schedule placements are untouched. An ingest-only plugin may change only the sources it added. |
| `remove_connector_sources` | `connector_label` | Remove every active source one plugin added, by its label, as `remove_source` removes one: each address is dismissed so nothing adds it again, then the source is archived. Full-access connections only. |

## Slack

ForeverLM reads Slack as the learner, through a token they granted, and never
posts, replies, or reacts. Only channels the learner has explicitly enabled are
visible; the rest of the workspace is not. A learner may connect several
workspaces: every tool considers all of them, each channel, message and file is
returned with the `team_id` and `workspace` name it came from, and a search runs
in every workspace and merges the hits. Nothing read from Slack is filed into
the library: a channel is a live conversation, and a saved copy of it was a
snapshot that read as current the moment it went stale. A PDF posted in a
channel can still be filed as the paper it is, as described below.

These tools are answered by the gateway rather than by a Mac or a hosted
account, because the gateway is the only place that holds the workspace
credential. Nothing is stored: a channel is read when asked, returned, and
forgotten.

| Tool | Parameters | Description |
|---|---|---|
| `list_slack_channels` | — | The channels the learner has enabled, with their names and the workspace each is in; `workspaces` lists the connected workspaces. |
| `read_slack_channel` | `channel_id`, `since_days?` | Recent discussion from one enabled channel, with thread replies, posted links, posted files, and exact URL/DOI matches to sources already in ForeverLM. Defaults to 7 days; any window up to ten years is accepted, and the result says (`truncated`, `oldest_read`) when the read filled up before the window began. |
| `read_slack_thread` | `channel_id`, `thread_ts` | One thread in full — root and every reply — from an enabled channel, however old. Takes the `thread_ts` a search hit or channel read names. |
| `search_slack_messages` | `query`, `limit?`, `channel_id?`, `since_days?`, `sort?` | Messages and files matching the query across every enabled channel in every connected workspace, as far back as Slack keeps. Hits from channels the learner has not enabled are counted, never shown. Each message hit carries `channel_id` and `thread_ts` for `read_slack_thread`; `workspaces_searched` says which workspaces answered, and a workspace whose grant predates `search:read` is named under `workspaces_needing_reconnect` rather than failing the search. |

To find a specific article, paper or file someone posted, search first:
`search_slack_messages` is one call where reading every channel's history was
many, and it reaches material older than any channel read carries. Slack search
matches whole words, so a distinctive phrase, a surname, a journal, or a URL
fragment works better than a full sentence. Searching needs the `search:read`
permission on the learner's Slack grant; a workspace connected before that
permission existed is asked to reconnect once at
[app.foreverlm.com/slack-connect](https://app.foreverlm.com/slack-connect).

A file posted in a channel is listed under `files` with its name, type, size,
permalink and a `download_url`. From a chat inside the ForeverLM app that
address is fetched as the learner: `attach_pdf_to_paper` takes it as `pdf_url`
to complete a paper already in the library, and `import_paper_from_url` takes
it as `url` with `source_url` set to the file's permalink to add a new one, the
permalink becoming the paper's canonical URL. A remote client can list the
files but not file them.

## Linear

ForeverLM reads Linear as the learner, through a grant they made with the single
`read` scope, and never creates, edits, comments on or assigns anything. There
is no mutation anywhere in the plugin, so nothing an assistant asks for can
change a workspace. Nothing read from Linear is filed into the library: an issue
is fetched when a chat asks, returned, and forgotten.

These tools are answered by the gateway rather than by a Mac or a hosted
account, because the gateway is the only place that holds the grant. The learner
connects Linear in Plugins › Linear, or at
[app.foreverlm.com/linear-connect](https://app.foreverlm.com/linear-connect),
and can connect more than one workspace, each its own grant. Every tool takes an
optional `workspace` (a workspace's name, URL key or id): omitted, it reads every
connected workspace and tags each result with the workspace it came from; an
identifier such as `ENG-123` is looked up in each workspace until one knows it.
A workspace that needs reconnecting, or does not answer, is named in the result
and does not stop the others.

| Tool | Parameters | Description |
|---|---|---|
| `get_linear_issue` | `issue`, `workspace?` | One issue by identifier (`ENG-123`) or id: description, state, priority, assignee, labels, project, team, URL, dates, sub-issues and every comment, oldest first. |
| `search_linear_issues` | `term`, `team_key?`, `limit?`, `workspace?` | Issues matching words, ranked by Linear's relevance, optionally within one team. Each hit carries its identifier and an excerpt of its description. |
| `list_linear_issues` | `team_key?`, `state_type?`, `assigned_to_me?`, `updated_since_days?`, `project?`, `limit?`, `workspace?` | Issues most recently updated first, filtered by team key, workflow state type (`triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`, `duplicate`), assignment to the learner, project, or how recently they changed. Says (`truncated`) when more matched than fit. |
| `list_linear_teams` | `workspace?` | The teams with their keys, names, descriptions and issue counts, and the workspace each belongs to. A team's key is the prefix of its identifiers. |
| `list_linear_projects` | `team_key?`, `status_type?`, `limit?`, `workspace?` | Projects most recently updated first, with status, health, lead, teams, progress, start and target dates. |
| `get_linear_project` | `project`, `workspace?` | One project by id or slug: description and content, its issues summarised by state type and listed, its recent updates with their health, and its comments. |

## GitHub

ForeverLM reads GitHub as the learner, through the ForeverLM GitHub App, whose
permissions are Contents, Issues, Pull requests and Metadata, all read. There is
no write anywhere in the plugin: it cannot push, comment, merge, open or
close anything, and a chat that wants to act is pointed at the URL. Nothing read
from GitHub is filed into the library: a file is fetched when a chat asks,
returned, and forgotten.

Where ForeverLM can read is decided by where the App is installed. The learner
authorizes the App once at
[app.foreverlm.com/github-connect](https://app.foreverlm.com/github-connect),
and installs it on the organisations and personal accounts whose repositories
it may read; `list_github_repositories` names the installations and the
`install_url` where another organisation is added. A notebook can be linked to
the repository it is about (`repository` on `create_notebook`, `update_notebook`
and `get_notebook`), and a chat working in that notebook is told to pass it.

These tools are answered by the gateway rather than by a Mac or a hosted
account, because the gateway is the only place that holds the grant. The Mac
carries twins of the same ten reads for the in-app chat.

| Tool | Parameters | Description |
|---|---|---|
| `list_github_repositories` | `query?`, `limit?` | Every repository in the organisations and accounts where the App is installed, newest push first, optionally filtered by words in the name or description. Call it first to learn a repository's `full_name` and default branch. |
| `get_github_repository` | `repository`, `ref?` | One repository's overview: description, default branch, language, topics, stars, open issue count, license, dates, its README (opening 20,000 characters) and its top-level files and directories. `repository` is `owner/repo` or the repository's github.com URL, here and below. |
| `list_github_files` | `repository`, `path?`, `ref?`, `recursive?` | The files and directories under a path. One directory by default, directories first; `recursive` lists everything beneath the path, cut at 2,000 entries with `truncated` set. |
| `read_github_file` | `repository`, `path`, `ref?` | One text file, decoded, with its size, blob sha and URL, cut at 100,000 characters (`content_truncated`). A binary file is refused with its URL; a file over 1 MB is reported with its download link. `ref` reads it as it was on a branch, tag or commit, a pull request's `head_sha` included. |
| `search_github_code` | `repository`, `query`, `limit?` | The files matching words, with the fragments that matched. Default branch only, whole words, ten searches a minute; qualifiers such as `path:` and `language:` are accepted. |
| `list_github_issues` | `repository`, `state?`, `labels?`, `since_days?`, `limit?` | Issues most recently updated first, filtered by state (`open` by default, `closed`, `all`), labels, and how recently they changed. Pull requests are excluded. |
| `get_github_issue` | `repository`, `number` | One issue in full: body (cut at 20,000 characters) and every comment oldest first. A pull request's number says so and points at `get_github_pull_request`. |
| `list_github_pull_requests` | `repository`, `state?`, `limit?` | Pull requests most recently updated first, with draft state, head and base branches, labels and dates. |
| `get_github_pull_request` | `repository`, `number` | One pull request in full: body, merge state, `head_sha`, the changed files with their status and line counts (no patches), the conversation and the inline review comments with path and line. |
| `list_github_commits` | `repository`, `ref?`, `path?`, `since_days?`, `limit?` | Commits newest first on a branch, tag or commit, optionally only those touching a path and within a number of days, with the full message cut at 2,000 characters. |

## Notion

ForeverLM reads Notion as the learner, through the ForeverLM connection, whose
capabilities are read content and read user information without email. There is
no write anywhere in the plugin: it cannot create, edit, move or comment on a
page, and a chat that wants to act is pointed at the URL. Nothing read from
Notion is filed into the library: a page is fetched when a chat asks, returned,
and forgotten.

What ForeverLM can read is decided in Notion, page by page. The learner
authorizes the connection in Plugins › Notion (or at
[app.foreverlm.com/notion-connect](https://app.foreverlm.com/notion-connect)),
ticking the pages and databases it may read in Notion's picker, and shares
another later from the page's own menu (**•••** → **Connections**). More than
one workspace can be connected, each its own grant; every tool takes an optional
`workspace` (a workspace's name or id): omitted, it reads every connected
workspace and tags each result with the workspace it came from, and a page or
database id is looked up in each until one knows it. A
database in Notion holds one or more data sources; these tools take either id
and resolve it.

These tools are answered by the gateway rather than by a Mac or a hosted
account, because the gateway is the only place that holds the grant. The Mac
carries twins of the same five reads for the in-app chat.

| Tool | Parameters | Description |
|---|---|---|
| `search_notion` | `query?`, `kind?`, `limit?`, `workspace?` | Pages and databases shared with ForeverLM whose titles match the words, or the most recently edited when there are none. `kind` is `page` or `database`. Each result carries `kind`, `id`, `title`, `url`, `parent` and `last_edited_time`. |
| `get_notion_page` | `page`, `include_content?`, `workspace?` | One page in full: title, url, icon, parent, dates, every property flattened to plain values, and its content rendered as text with nested blocks indented, cut at 400 blocks or 60,000 characters (`content_truncated`). Sub-pages appear as `[Page: title] (id)` lines. `page` is an id, dashed or not, or a notion.so URL, here and below. |
| `list_notion_databases` | `query?`, `limit?`, `workspace?` | The databases shared with ForeverLM, most recently edited first, with `id`, `title`, `description`, `url`, `parent`, `database_type` and property names. |
| `get_notion_database` | `database`, `workspace?` | One database's schema: every property with its type and, for selections and statuses, the options it offers. A database with several data sources lists them so one can be chosen. |
| `query_notion_database` | `database`, `filter?`, `sorts?`, `limit?`, `cursor?`, `workspace?` | The database's rows, each a page with its properties flattened, with Notion's own `filter` and `sorts` objects passed through unchanged. 25 rows by default, 100 at most; `next_cursor` continues. |

## Posting to X

ForeverLM can post to X as the learner, through the X plugin with posting
permission (Plugins › X). A post is public at once, so the assistant
shows the exact text and waits for the learner's yes.

| Tool | Parameters | Description |
|---|---|---|
| `create_x_post` | `text`, `reply_to_post_id?`, `account?` | Post on X, or reply to a post. With one X account connected it posts as that account; with several, `account` (the user id or @username from `get_plugin_connections`) is required, and the call refuses and names the connected accounts without it. Returns the post's id and URL, and `posted_as`. A sign-in from before posting support must reconnect once. |

## The day (the Mac's Calendar)

The learner's day and week are their Mac's Calendar; the quarter they serve is
a plan Page (`get_plan`, see [Plan](/plan)). An assistant reads the quarter's
plan, then the day's or the week's events and plans them by adding each block — a stretch
of work, a reading, a review, email and admin, a break — as an event. It lands
on the calendar new events go to (Plugins › Calendar), and shows at
once in the Calendar app, in the bottom-left **Now** chip, and on the learner's
phone through their calendar account. A Google, Exchange or subscribed calendar
the Mac's Calendar holds is part of the day like any other. An event with other
people on it is a meeting: it stays at its time, and only the Calendar app may
change it.

What the calendar cannot hold stays ForeverLM's: the day's log of what
ForeverLM saw the learner actually do. Calendar access is granted to the Mac by
macOS and the log is kept there, so every tool here needs an active Mac;
without one the call is refused with an explanation rather than answered.

Times are 24-hour `HH:MM`; a date is `YYYY-MM-DD`, `today` or `tomorrow`, and
defaults to today on the learner's Mac.

| Tool | Parameters | Description |
|---|---|---|
| `get_calendar_events` | `date?`, `days?` | The events on the calendars that make up the day, for one day or up to 14 from `date`: each with `event_id` (and `occurrence_date` for one occurrence of a recurring event), `title`, `calendar`, `start` and `end` on the learner's clock, `start_at` and `end_at`, `all_day`, `when` (`ended`, `now` with `minutes_left`, or `ahead`), `location`, `join_link`, `notes`, `attendees`, `has_other_people` and `editable`. Each day also gives its `weekday`, `relative_day`, the hours the learner's day runs (`day_starts`, `day_ends`) and its free stretches — `free_from_now` on today, `free` on a day ahead — which is where a plan goes; `new_events_calendar` names where new events go. Needs the Mac's Calendar on; the error says how to turn it on. |
| `create_calendar_event` | `title`, `date?`, `start?`, `end?`, `duration_minutes?`, `all_day?`, `notes?`, `location?`, `url?`, `calendar_id?` | Add one event: how a day is planned, one block at a time. Pass `start` with `end` or `duration_minutes` (the way past midnight), or `all_day`. It goes to the calendar new events go to unless `calendar_id` names another that takes events. Put what the hour is for in `notes`: the next step, and the `foreverlm://` link of the source or Page, so it opens from the event. A block on one topic may also carry its notebook's `[Title](foreverlm://notebook/<id>)` link, which the Now chip opens. The calendar allows overlapping events, so read the day first and never plan over a meeting. Returns the event with its `event_id`. |
| `update_calendar_event` | `event_id`, `occurrence_date?`, `span?`, `title?`, `date?`, `start?`, `end?`, `duration_minutes?`, `all_day?`, `notes?`, `location?`, `url?`, `calendar_id?` | Move, retitle or rewrite an event the learner owns alone (`editable`). `date` moves it to another day at the same time; a new `start` keeps its length unless `end` or `duration_minutes` is passed; `""` clears `notes`, `location` or `url`; `calendar_id` moves it to another calendar. On a recurring event, `occurrence_date` picks one occurrence and `span: "future"` changes it and every later one. An event with other people on it is refused. Returns the event as the calendar now holds it. |
| `delete_calendar_event` | `event_id`, `occurrence_date?`, `span?` | Remove an event the learner owns alone, or with `span: "future"` a recurring event from one occurrence on. Not undoable: the assistant removes only what the learner asked it to, or an event it added for them in the same conversation, and asks first otherwise. An event with other people on it is refused; the learner declines or cancels it in the Calendar app. |
| `get_day_activity` | `date?` | One day's log: what ForeverLM saw the learner do, span by span — `reading`, `listening`, `watching`, `chat`, `doc` — each with `activity_id`, its times, `duration_minutes`, the id of the thing and a `foreverlm://` link (a span still going today is `ongoing` and runs to `now`), with `logged_minutes` by kind, the day's learning bouts with their write-ups, `minutes_learned`, `weekday` and `relative_day`. The Activity pane shows the same log. Read it beside `get_calendar_events` to see where a planned day went. |
| `delete_day_activity` | `activity_id` | Forget one span of the day's log, the Activity pane's Delete on a sitting. The sources stay. Not undoable; `activity_id` comes from `get_day_activity`. |
| `get_day_settings` | — | Settings › General › Day: `day_start_hour` and `day_end_hour`, the hours the learner's day runs (6 and 24 unless the learner set them; the pair follows the account to their other Macs), `suggest_planning_the_day` and `force_planning_the_day` (this Mac's), and `notifications_status` — whether macOS lets ForeverLM notify on this Mac at all (`allowed`, `refused` or `not_asked`) — with a `notifications_note` saying what a refusal costs. |
| `set_day_settings` | `day_start_hour?`, `day_end_hour?`, `suggest_planning_the_day?`, `force_planning_the_day?`, `request_notifications?` | Change Settings › General › Day exactly as the pane does. `day_start_hour` (0–23) and `day_end_hour` (1–24, 24 midnight) set the hours of the day, the end after the start. `suggest_planning_the_day` (on unless switched off) is whether this Mac asks *Plan your day?* on a morning whose calendar holds nothing the learner planned (meetings with other people and recurring events do not count): a card at the bottom left of the Studio window that waits until it is answered, and a notification once if ForeverLM is not in front. `force_planning_the_day` (off unless switched on) makes the learner plan: on such a morning the planning chat opens by itself the first time they are at the Mac, and the card cannot be closed until the calendar holds a plan; it does nothing while `suggest_planning_the_day` is off. `request_notifications: true` is the pane's **Allow Notifications**: if macOS has never asked on this Mac, it shows its prompt there for the learner to answer; the call does not wait, and `notifications_request` says what happened. A refusal is undone only by the learner, in System Settings → Notifications. Returns the settings and `changed`. |

## Meeting series

A meeting series is a folder of sessions, each a source holding its
transcript, notes and chat. A recurring series can be given the weekdays and
hour it meets. A series with a schedule has each session's action items read out of its
transcript as it lands. The schedule and the action items are the ForeverLM
app's own records, so every tool here needs an active Mac.

| Tool | Parameters | Description |
|---|---|---|
| `set_meeting_schedule` | `group_id`, `weekdays?`, `start?`, `duration_minutes?`, `timezone?`, `clear?` | When a recurring meeting series meets: weekdays 1 = Sunday to 7 = Saturday, a 24-hour `start` in an IANA `timezone`, a length. `clear` true removes it. The same as **Schedule…** on the series in the sidebar. |
| `list_meeting_action_items` | `group_id?`, `source_id?`, `latest_only?` | What a series' session transcripts asked someone to do, each with `item_id`, `text`, `owner` and `due` when the transcript named them, `source_id` and `done`. `latest_only` returns the most recent session's items, open first. |
| `set_meeting_action_item_done` | `item_id`, `done?` | Tick an action item off (the default) or reopen it. |
| `merge_meeting_sessions` | `group_id?`, `date?`, `source_ids?` | Fold the sessions of one series that are really one sitting into one session — the series' **Merge Same-Day Sessions** in the sidebar. A free Zoom account ends a call after forty minutes and the host starts a new one, so a standup arrives as two sessions; a pair like that is folded on its own as the second transcript lands (same local day, started within four hours), and this is the hand-driven form for sessions split before that or filed by hand. `group_id` folds every day of the series that holds more than one finished session, `date` (`YYYY-MM-DD`) one day only, `source_ids` exactly those sessions. The session that started first keeps its id, title and date; the others' transcript, notes, chat and recording sections follow it under a “Reconnected at HH:MM” line, their files and links move to it, and their rows are archived so the same recording is never filed again. Idempotent. |
| `list_meeting_groups` | — | Every meeting series with its `group_id`, session count and sidebar image. |
| `get_meeting_group` | `group_id` | One series with its sessions' source ids and their artifacts. |
| `import_meeting_transcript_files` | `folder_path`, `group_title`, `source?` | Import sessions from JSON files on the Mac (title, start time, transcript, notes, chat, link), such as an export from Read AI; sessions already imported are skipped. |
| `attach_meeting_artifact` | `source_id`, `file_path`, `kind?` | Add a text file on the Mac (a transcript, notes, a chat log) to a session as a section of its own; the same kind again replaces it. |
| `transcribe_meeting_recording` | `source_id`, `approved_spend_usd?` | Transcribe a session's recording from Drive with speech-to-text and attach the transcript. A long recording takes minutes; `cancel_ai_work` stops it. |
| `merge_meeting_groups` | `source_group_id`, `target_group_id` | Merge one series into another, as dropping a meeting folder onto another does; the old id keeps resolving. |
| `set_meeting_folder_image` | `group_id`, `image_url?` | **Set Folder Image…**: a series' own logo in the sidebar; without `image_url`, the default icon again. A web address follows the learner's account; a file path shows only on this Mac. |
| `delete_meeting_group` | `group_id` | **Delete Meeting Group**: every session and its artifacts go; the Drive folder and the recordings behind it are untouched. Not undoable: confirm the title and session count first. |

## Learning bouts

A learning bout is a stretch of learning with a clock on it, on its own or on
one of the day's calendar events. It ends in a write-up — what was learned, and
what is still not understood — and that write-up, never the clock, is what
earns the break that follows. A bout past its time keeps running and says how
far over it is; nothing ends it but the learner. Only one bout runs at a time,
and the bout is the Mac's own record, so every tool here needs an active Mac.

A bout is in one of five phases, derived from its stamps rather than stored:
`learning` (the clock is running), `writing` (stopped, the write-up owed),
`earned` (written up, a break waiting), `resting` (on that break), and
`complete`. Call `get_learning_bout` before any of the others.

| Tool | Parameters | Description |
|---|---|---|
| `get_learning_bout` | `date?` | The bout running now and the day's finished ones with their write-ups: each with `bout_id`, its phase, its title, when it started, how long it has run, how far past its time it is, and the break it has earned. |
| `start_learning_bout` | `event_id?`, `occurrence_date?`, `title?`, `minutes?`, `notebook_id?`, `source_ids?` | Put a clock on a stretch of learning. `event_id` (from `get_calendar_events`, with `occurrence_date` for one occurrence of a recurring event) runs one of the day's events and takes its title and what is left of its time; otherwise pass a `title`. Refused while another bout is running. |
| `end_learning_bout` | `bout_id` | Stop the clock without writing the bout up yet. The write-up is still owed and no break is earned until it is filed. |
| `write_up_learning_bout` | `bout_id`, `learned`, `unclear?`, `break_minutes?` | File what the bout produced, which is what earns its break. Ask the learner both questions and file their own words rather than a summary; the second is the more valuable half. Stops the clock if the bout is still running. |
| `set_learning_bout_break` | `bout_id`, `running`, `minutes?` | Start (`true`) or end (`false`) the break a write-up earned. A break started counts down on every one of the learner's devices, the phone's widget included. Refused on a bout with no write-up; ending a break never started records it as declined. |
| `abandon_learning_bout` | `bout_id` | Let a bout go without a write-up. The learning is recorded as having happened and no break is earned. Only when the learner says the time went nowhere. |

The break is a minute of rest for every nine minutes learned, floored at five
and capped at twenty, and it is earned from the minutes actually learned rather
than the time the bout was set for.

## Scheduled tasks

A scheduled task is a recurring instruction ForeverLM sends to itself. The
instruction is ordinary chat text: when the task comes due, a signed-in client
opens a new chat with this same tool surface and sends it, so the result is a
conversation the learner reads and continues.

A run cannot see the conversation that created it, so the instruction must stand
alone — carry `notebook_id` and `source_ids` rather than writing "this". Creating
a task does not run it: runs happen on a client that is open when the task
comes due, or at once with `run_scheduled_task_now`.

A run tries hard before it fails. When the Default Model is busy or
rate-limited, the run moves through the Chat model's backups (set with
`set_ai_task_settings`, target `backups`, `backups_for` `chat`), and a run that
still fails in a way time may fix is tried again on the same receipt: up to
five tries, the next after 5, 15, 45 and 120 minutes, within 12 hours of when
it was due. The Tasks pane's **⋯ › Keep This Mac Awake for Tasks** (`tasks.keep_mac_awake`) keeps the Mac
from idling to sleep while a task is due and it is plugged in.

| Tool | Parameters | Description |
|---|---|---|
| `create_scheduled_task` | `title`, `instruction`, `cadence?`, `hour?`, `minute?`, `weekday?`, `day_of_month?`, `date?`, `time_zone?`, `notebook_id?`, `source_ids?`, `enabled?` | Create a recurring task whose instruction is sent as a chat when it comes due. Wall-clock times are anchored to the task's own IANA zone. |
| `list_scheduled_tasks` | `include_runs?` | The learner's scheduled tasks. They are not the Schedule, which places sources on study days. |
| `get_scheduled_task` | `task_id` | One task with its recent runs and the chat each run made. |
| `update_scheduled_task` | `task_id`, `title?`, `instruction?`, `cadence?`, `hour?`, `minute?`, `weekday?`, `day_of_month?`, `date?`, `time_zone?`, `notebook_id?`, `clear_notebook?`, `source_ids?`, `enabled?` | Change a task; omitted fields stay as they are. `clear_notebook` detaches its notebook, and `source_ids` replaces its sources. |
| `run_scheduled_task_now` | `task_id` | Run a task now, besides its cadence, as a new chat on an open, signed-in client; `cancel_ai_work` stops a run on this Mac. |
| `delete_scheduled_task` | `task_id` | Delete a task; the chats it made stay. |

## Memory cards

A card is a question with its answer, standing on a passage of one of your
sources. Cards drafted for you wait in Memory's **To Check** until you keep,
edit or skip each one; only a kept card is ever asked, first the day after you
keep it. A draft waits until you go through it and never expires,
and the cards from before cards (questions you missed in a walkthrough or a
course quiz) are offered there once. Cards are your own: they never enter a
team. An assistant can run your card review too: `get_due_cards` deals today's
cards as **Start Review** does, with the wording to ask; the assistant asks
you to answer each in your own words before it shows the answer, judges your
answer against the card as ForeverLM's **Check** does, and
`record_card_result` records each answer as **Forgot** or **Remembered** would.
To review some of your cards in ForeverLM itself — a topic, a source — the
assistant chooses them from `list_cards` and `practice_cards` opens the card
review on them in the app.
All of these need the Mac open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `draft_cards` | `source_ids?`, `notebook_id?`, `count?`, `focus?`, `confirm_cost?`, `approved_spend_usd?` | ForeverLM's own card drafting, which a Make Cards chat also uses when asked: ForeverLM drafts the cards with your Card Drafting model from each source's whole text, and they wait in To Check ticked, so one **Keep Cards** keeps them. Name sources with `source_ids`, or pass `notebook_id` alone for the Notebook's own ticked sources. `count` is `auto` (about 4 a source, at most 40) or a number of cards from 1 to 40. A walkthrough's questions become cards with no model call; the rest start from the source's review-guide questions, your highlights and notes, and its ideas, and nothing the source's cards already hold, kept or skipped, is drafted again. A source too long for the model's window is read as evenly spaced excerpts, and the answer says so (`sampled`); a card whose passage is not found in its source is reported, never offered. An unknown `source_id` refuses the whole call. The first call prices the drafting and starts nothing until you agree, unless it is free; then it drafts in the background (`work_id`; `cancel_ai_work` stops it), and `list_cards` shows the cards and what the run drafted (`drafting`). |
| `save_card_drafts` | `cards`, `kept_by_default?` | Save cards an assistant drafted to wait in To Check. Each card has a `source_id`, a `front`, a `back`, an optional `why` (one plain sentence on why the back is true, never the back again or what the author did), an optional `seed`, and a source-grounding `quote`. Images are the default: when a relevant slide, paper figure, diagram or other durable ForeverLM picture materially supports recall, include it in `front_images` or `back_images`; omit imagery only when no useful picture is available. Each image list takes up to four image-tool Markdown lines or `{target, alt}` references; multiple images share a comparison grid. One entry per face may instead be a saved animation (from `save_animation` or `list_animations`), by its `foreverlm-site://<animation_id>/` address: the card plays it inline, on the back only once the back shows. Local paths, web URLs, chat attachments, missing images, a second animation on one face and an animation the library does not hold are refused. A card is about an idea, and an idea is often printed in several sources: when other sources state what the card asks, name each in `also_from` (`{source_id, quote}`, at most 5; `find_card_sources` finds them) and the card stands on all of them. A link whose source does not print its quote is left off and listed under `not_grounded_links`. A card whose quote is absent is `not_grounded`; an unknown source refuses the call; an existing seed or question is `already_drafted`. `kept_by_default: true` ticks cards the learner asked for. At most 100 cards a call. A card must stand on its own: every card is checked first, with your Card Wording Check model, and one whose question or answer points at its source unnamed ("this lecture", "the paper") is reworded once (`reworded`) or not saved (`not_standalone`); when the check cannot run, the source's cards are not saved and `sources_not_saved` says why. |
| `list_cards` | `status?`, `notebook_id?`, `source_id?`, `limit?` | `to_check` (the default): drafts and cards from before cards, with their face, source, optional `front_images` / `back_images`, quote and keep state; `sources` lists every source a card stands on, its own first, each with the quote it stands on there. `kept`: kept cards with the wording to ask, schedule and `sources`. `all`: both. Notebook/source filters narrow them. With cards to check, `drafting` describes recent drafting runs. |
| `list_source_card_coverage` | `scope?`, `notebook_id?`, `limit?` | List the sources of your library with how many cards each has, as Memory's Sources section does. The goal is at least one card for each source and every source worth its weight: go through the sources with `status` `none` and give each a verdict. Make Cards is `save_card_drafts` (cards the assistant drafts itself; `draft_cards` only on your word) and, for a source that has some, more of them; Not Worth Keeping is `remove_source`, only when you say so. `scope` `without_cards` (the default) lists the sources no card covers, `all` lists every source; each has `source_id`, `title`, `source_type`, `date_added`, `status` (`none`, `to_check`, `kept` or `retired`) and `cards` (kept cards). `notebook_id` narrows to one Notebook's sources. Also returns `without_cards` and `total`. Reads only; free. |
| `find_card_sources` | `card_id?`, `question?`, `answer?`, `source_ids?`, `notebook_id?` | Find the other sources of the library that may also state what a card asks, so it can stand on every source that prints it. Pass a `card_id` (a card to check or a kept card), or the `question` and `answer` of a card about to be saved. Returns the nearest passages of other sources (up to 4), retrieved and not judged: the assistant keeps only those that state the card's answer in substance, and names them with a quote in `also_from`. `source_ids` or `notebook_id` narrow the search; sources the card already stands on are never listed. Reads only. |
| `triage_cards` | `decisions?`, `keep_source_ids?`, `skip_source_ids?` | Keep or skip cards to check, as To Check does, on your word. A keep decision can replace `front`, `back`, `why`, `front_images` or `back_images`; `[]` removes that face's pictures, and one entry per face may be a saved animation's `foreverlm-site://<animation_id>/` address. On a draft, `also_from` (`{source_id, quote}` each) chooses the other sources the card is kept on, replacing those it was drafted with; `[]` keeps it on its own source alone. A kept card stands on those sources for good. A card from before cards is kept already, so a new question alone rewords it and a new answer or picture list starts it over. Skipping a draft drops it for good; skipping a card from before cards retires it. Source-wide ids decide every waiting card on those sources. |
| `get_due_cards` | `notebook_id?`, `limit?` | Today's cards in review order, optionally for one Notebook. Each has its ids, wording, answer, why, optional `front_images` / `back_images`, source and quote, and `sources` (every source the card stands on, each with its quote). Show front images with the question, and show nothing of the back until the learner has answered in their own words (an "I don't know" counts as forgot). Also returns `sitting_id` and what the day's minutes leave over. Reads only. |
| `record_card_result` | `card_id` \| `item_id`, `remembered`, `asked?`, `sitting_id?`, `practice?` | Record one answer, as **Forgot** or **Remembered** does in the card review, after the learner answered in their own words and you judged the answer against the card (or they overruled you): the wording asked becomes the attempt's question and the card's schedule moves. `card_id` (or `item_id`) from `get_due_cards` or `list_cards`. One answer per card per sitting counts; a card not due yet is `not_counted`, since an early answer never stretches an interval, and a retired card is never recorded. `practice: true` is for practice you asked for: a new card then counts on the day you kept it. A card still to check is refused until it is kept. |
| `practice_cards` | `card_ids`, `title` | Open ForeverLM's card review on the Mac over kept cards the assistant chose — "show me my cards on mitochondria" — rather than today's review. The assistant reads `list_cards` with `status: kept`, chooses the cards by what each asks, and passes their `card_id`s with a few words saying what they are about (`title`). The review takes the window you last used, as practice you asked for: the due and new cards first, whose answers count, then the ones not due yet, whose answers never move their schedule. You answer each card in the app. Returns how many cards were dealt and `not_found` for any id no kept card answers to; refused while a card review already has that window. |
| `update_card` | `card_id` \| `item_id`, `front?`, `back?`, `why?`, `front_images?`, `back_images?`, `start_over?`, `always_ask?`, `retire?` | Change a kept card, as All Cards does, on your word. A new `front` alone rewords it and keeps its schedule. A new `back`, `why` or image list, or `start_over: true`, starts it over as a new card, first asked tomorrow; `[]` removes that face's pictures. An image list takes one saved animation per face (its `foreverlm-site://<animation_id>/` address, from `save_animation` or `list_animations`), which the card plays inline. `always_ask` controls wording variation and `retire: true` retires it. A card still to check takes `front_images` or `back_images` alone, with its `card_id`, whether or not it is on screen: they are saved with the card, its words are untouched, and the learner's Keep carries them (Skip drops them). New words are checked as `save_card_drafts` checks a draft: words that point at the source unnamed are reworded once, or the change is refused with the reason. |

## Study practices

A study practice is a way of studying worth keeping: review in the morning, recall a
source after reading it, take fewer new cards a day. Each has a short title, why it
helps, the rule the card review, drafting and the tutor follow once you adopt it, and,
when ForeverLM found it in your history, the evidence and the minimum sample behind it.
ForeverLM's own rules are off for now, so practices come from you or an assistant.
Practices are your own and never enter a team. They need the Mac open and connected,
on ForeverLM's new iCloud sync.

| Tool | Parameters | Description |
|---|---|---|
| `list_practices` | `status?` | Your study practices, each with `practice_id`, `title`, `why`, `status` (`proposed`, `adopted`, `dismissed`, `retired`), `origin` (`rule`, `user`, `ai`), `rule`, `setting_change` when adopting it changes a setting, its evidence and when it was decided. `status` narrows the list. Reads only. |
| `decide_practice` | `practice_id`, `decision` | Adopt, dismiss or retire a practice, on your word. Adopting one that changes a setting (new cards a day) changes it as Settings does. The decision follows you to your other devices, and a later proposal of the same practice never undoes it. |
| `set_practice` | `practice_id?`, `title?`, `why?`, `rule?`, `status?`, `scope?`, `suggested?` | Without `practice_id`, a new practice: yours, adopted at once, or with `suggested: true` an assistant's suggestion waiting for you to adopt or dismiss. With `practice_id`, change its title, why, rule, scope or status. `rule` is `{kind, params}`: `reviewWindow`, `interleave`, `retrievalAfterReading`, `draftSeeds`, `newCardsPerDay` or `walkAfterReading`. `scope` is `all`, `nb:<notebook id>`, `crs:<course id>` or `type:<source type>`. |

## Mnemonic readings

A mnemonic reading is a book's chapters, or any chapter, paper or article, read
as their own text with a recall question after each passage it tests, the way
quantum.country's essays are written. You answer in your head, show the answer
and grade it; the first answer keeps the question as a Memory card, remembered
or not, and the card review asks it again on its schedule. The reading holds
only its questions; what you answered lives in Memory. All of these need the
Mac open and connected.

| Tool | Parameters | Description |
|---|---|---|
| `generate_mnemonic_reading` | `source_ids?`, `book?`, `notebook_id?`, `density?`, `reading_id?`, `confirm_cost?`, `approved_spend_usd?` | Make a mnemonic reading, as a Notebook's Studio or the Reader's **Make Mnemonic Reading** does: your Mnemonic Reading Writing model writes the questions from each source's whole text, one request a source, and a source too long for the model's window is read in consecutive parts, never sampled. Name sources with `source_ids` in reading order, a `book` (its id or title) for all its chapters in order, or `notebook_id` alone for the Notebook's ticked sources; with `notebook_id` the reading is filed in that Notebook. `density` is `auto` (about one question for every 350 words, at most 24 a source), `fewer` or `more`. A question whose passage its source does not print is dropped. An unknown `source_id` refuses the whole call. The first call prices the writing and starts nothing until you agree, unless the model is free; then it writes in the background (`reading_id` and `work_id`; `cancel_ai_work` stops it, the sources already written keeping their questions). `reading_id` alone writes a reading's pending sources. |
| `save_mnemonic_reading` | `sources`, `title?`, `notebook_id?`, `reading_id?` | Save a reading whose questions an assistant wrote. `sources` in reading order, each a `source_id` with its `questions` in the order of its text: a `quote` (the last sentence of the passage it tests, copied word for word), the `question`, the `answer`, and an optional one-line `why`. A question whose quote the source does not print is not saved (`not_grounded`). An unknown `source_id` refuses the whole call. Pass `title` (and `notebook_id` to file it in a Notebook) for a new reading, or `reading_id` to add questions to one; a question it already holds is not saved twice. Each question is checked, as `save_card_drafts` checks a card, for pointing at its source unnamed: reworded once, or not saved. |
| `get_mnemonic_reading` | `reading_id` | A reading's sources in reading order (`written`, or `pending` while their questions are not written) and every question with its `question_id`, `quote`, `question`, `answer` and `why`, and where it stands for you: `unanswered`, `kept` with its last grade and `next_due_at`, `due`, or `retired`. `counts` gives questions, answered and due. Reads only. `list_docs` lists readings as kind `mnemonic_reading`; `write_doc`, `edit_doc` and `publish_doc` refuse them. |
| `answer_mnemonic_question` | `reading_id`, `question_id`, `remembered`, `sitting_id?` | Record an answer, as the reading's own **Forgot** or **Remembered** does. The first answer keeps the question as a card (`kept`). A card kept already is answered as the card review answers it: recorded only while it is due and once a sitting (`already_recorded`), `not_counted` otherwise, never for a retired card. Without `sitting_id`, a day's answers over MCP are one sitting. |

## Review sessions

A completed MCP review keeps the actual exported transcript, not just summary
metadata. Source links and Schedule completion are updated only after the review
is durably recorded.

| Tool | Parameters | Description |
|---|---|---|
| `start_review_session` | `topic`, `source_id?`, `source_ids?`, `notebook_id?`, `operation_id?` | Create a durable source-grounded review session. `notebook_id` links it to a Notebook (`list_notebooks`) or a Goal (`list_goals`); a review linked to a Goal counts toward it. |
| `memory_review` | `goal_id?`, `limit?`, `start_session?`, `operation_id?` | A memory review for the assistant to conduct: what is due for retrieval now, and by default a linked session to do it in. It is not the app's own daily review, which is the card review started from **Memory** in ForeverLM; both move the same schedules, and a card never yet asked is left to the app, which introduces new cards a day's allowance at a time. `memory_items` carry a stable `item_id`, a private rubric, the learner's history with the concept and its source anchors, so the question is written fresh rather than recited, except for a card the learner kept: its entry has `ask`, the wording to ask as written and record as the attempt's `prompt`; `new_items` are sources consumed but never retrieved, and a first review needs a `semantic_target`, rubric and exact evidence excerpt kept for `end_review_session`. Ask one question at a time, then close with `end_review_session` and structured `memory_attempts`: graded items are rescheduled and validated first reviews become durable memory items. `start_session: false` is a read-only briefing that starts no session and marks no item served. To run the card review itself, card by card, use `get_due_cards` and `record_card_result` (Memory cards). Needs the Mac open and connected — the memory schedule is the app's own. |
| `end_review_session` | `session_id`, `overall_score`, `summary`, `transcript?`, `chat_export?`, `source_ids?`, `topic?`, `gaps?`, `memory_attempts?` | Complete the review, save its transcript, and link Schedule state. The always-on host requires a transcript because it does not own an in-app chat; structured Memory Review evidence requires an active Mac. |
| `get_review_sessions` | `topic?`, `source_id?` | List saved reviews and chats, optionally filtered by topic or source. |
| `update_review_session_sources` | `session_id`, `source_ids` | Replace the sources linked to a review or chat. On a day's memory review (`memory-YYYY-MM-DD`) a source left out is removed from the day, the same as the × on its chip in the app: the tutor stops asking about it when the review is next opened, and a reopen on any device leaves it out. |
| `get_review_session_transcript` | `session_id` | Return the stored transcript and parsed exchanges. Accepts a chat link, `foreverlm://chat/<id>` — what **Copy Link** in a chat's sidebar menu copies — in place of the id, as does every tool that takes a `session_id`. A chat still in progress returns its turns so far. |
| `import_review_chat` | `title`, `transcript` \| `transcript_file`, `session_id?`, `notebook_id?`, `source_ids?`, `mark_reviewed?`, `summary?`, `overall_score?`, `model_provider?`, `model_id?`, `started_at?`, `ended_at?` | Import an externally completed review as searchable per-turn exchanges and link its completed state. `transcript_file` reads the assistant's own record of the chat on the Mac (a Claude Code session id or its file) in place of `transcript`, so the chat is stored word for word; `started_at` and `ended_at` draw it on the day's log at the hours it ran. `mark_reviewed: false` saves a chat that researched or discussed its sources without counting them as reviewed or checking them off on the Schedule, and the chat keeps that choice: the sources a later call adds with its `session_id` stay unreviewed unless that call passes `mark_reviewed: true`. On the first chunk, `notebook_id` files the chat directly under that Notebook, or under a Goal from `list_goals` (a chat clearly about a Goal's sources belongs on that Goal, where its row and editor list it), without changing any source pool. A chat too long for one call arrives in chunks: import the first without `session_id`, then pass the id on the `session_id:` line that call's answer ends with as `session_id` with each further chunk and its turns are appended after the stored ones; the title and Notebook are kept, `source_ids` are added, and a summary, score or model given replaces the stored one. A retried chunk identical to the stored tail is not stored twice. The same two calls keep an ordinary conversation about your sources as it happens: the assistant saves the first question and answer without `session_id`, keeps the id, and appends each later exchange with it as soon as it has answered, so every chat about a source is in ForeverLM whether or not it ever ends. The hosted service requires explicit `source_ids` on a first import; only an active Mac can use its current app selection. |
| `search_review_sessions` | `query`, `limit?` | Search saved review topics, summaries, and transcript text. |
| `update_review_session` | `session_id`, `title?`, `notebook_id?`, `is_hidden?`, `is_pinned?` | Rename a chat, file it under a notebook (`""` moves it out to the ungrouped Chats), pin it to Home's Pinned, or hide it from the sidebar. |
| `delete_review_session` | `session_id` | Delete a review or chat. |
| `list_review_session_links` | — | The saved Claude and ChatGPT review share links. |
| `set_review_depth` | `depth`, `source_id?`, `source_type?` | How much of a memory review one source, or a whole kind of source, gets: `quick` (the contour only), `standard` (a probe or two more) or `deep` (the full plan), as in "keep podcasts quick". |
| `daily_review` | `goal_id?`, `start_session?` | Today's chat-first review for a Goal: its open gaps, sources due again, the deadline's pace and reading in progress, in one review chat. Without `goal_id`, a menu of active Goals; `start_session: false` is a briefing only. Writes nothing to the Schedule. |
| `daily_quiz` | `goal_id?`, `date?`, `start_session?` | Today's quiz for a Goal: new and review sources paced to its end date, with earlier sessions, open gaps and pending suggestions. One deep question at a time, closed with `end_review_session`. |
| `cohort_review` | `goal_id?`, `start_session?` | Today's cohort review: what the learner read or heard in the last ten days or so, older sources due again, and one or two from another stretch of time to ask across, each with its guide, the learner's highlights and what they made of it before. When the app has planned the day by topic, `topics` lists them to follow in order. Closed with `record_understanding`. |
| `record_understanding` | `session_id`, `session_summary`, `updates` | Close a cohort review: rewrite, whole, what the learner now understands about each source discussed, and add a short summary. Only sources the session covered may be written. |

## Hosted and active-Mac execution

The official plugin has one stable list and public input contract regardless
of execution mode. Many calls can run from the always-on hosted CloudKit
projection, including creating a notebook and attaching sources to it. The
semantic index (and with it `create_notebook`'s `discover` option), iCloud Drive
workspace-file bodies, structured Memory Review completion, and ambient app
selection remain device-local. Calls
that need those capabilities route to an active Mac when available; otherwise
`get_mcp_status` and the affected response state the limitation directly.
Enabling hosted MCP never removes a tool or silently substitutes a different
result.
