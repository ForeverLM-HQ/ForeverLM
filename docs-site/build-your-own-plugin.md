# Build Your Own Plugin

ForeverLM deliberately ships very few built-in plugins. Any service you can
reach with code (Readwise, RSS, Zotero, Fireflies, a company wiki, …)
can feed your library through a **plugin you build yourself**, in minutes,
usually by asking an AI assistant to write it for you.

Your plugin runs on *your* side, with *your* credentials for the service,
and pushes sources into ForeverLM through the same MCP server your AI
assistants already use — under a restricted **ingest-only** permission that
keeps it safe even if the code is sloppy or the token leaks.

## Why this is safe

When your plugin connects, it asks for the `mcp:ingest` scope instead of
full access. An ingest-only connection:

- **can** add sources, update the sources *it* added, import papers through the
  complete paper pipeline, and check server status;
- **cannot** read your knowledge base, delete or modify anything else, touch
  your notebooks or Schedule, or use any other tool.

You approve it once, in the same consent flow as any assistant — the approval
screen says exactly this in plain words. Every source it adds is labeled with
the plugin's name, so you can always see what came from where, and one
command (`remove_connector_sources`, from Claude or any full-access assistant)
removes everything a plugin ever added. A plugin connects over MCP, so, like
any assistant, it works while your MCP is in its 7 free days or paid for. ForeverLM charges nothing per tool call, but the gateway
rate-limits every client, so a runaway script runs out of rope quickly.

## The recipe (give this to your assistant)

The fastest path: **ForeverLM → Plugins → Build Your Own →
Copy Setup Prompt** — that button copies this exact recipe with your personal
MCP URL already filled in. The same pane lists every plugin you've
approved, with its logo, how many sources it has added, and buttons to remove
its access or its sources.

Or copy the prompt from here and fill in the blanks yourself:

> Build me a small plugin script that syncs **[SERVICE — e.g. my Readwise
> highlights]** into ForeverLM, and set it up to run **[SCHEDULE — e.g. once a
> day]**.
>
> ForeverLM exposes an MCP server (Streamable HTTP) at my personal URL, shown
> in ForeverLM → Settings → MCP. The plugin must:
>
> 1. Register itself as an OAuth client: `POST {my-url}/oauth/register` with a
>    JSON body including `"client_name"` set to a short human name for this
>    plugin (this name labels every source it adds), optionally
>    `"logo_uri"` set to an https icon URL (shown next to the plugin in
>    ForeverLM's Settings), your redirect URI in `"redirect_uris"`, and
>    `"token_endpoint_auth_method": "none"`.
> 2. Do the OAuth 2.1 authorization-code flow with PKCE (S256) against
>    `{my-url}/oauth/authorize` and `{my-url}/oauth/token`, requesting
>    **`scope=mcp:ingest`**. I will approve the request in ForeverLM (or with
>    my pairing code if I'm not at my Mac). Store the refresh token and refresh
>    as needed — the granted scope survives refresh. If the token endpoint
>    answers `invalid_client`, ForeverLM no longer knows this registration: I
>    removed the plugin's access, or ForeverLM was reinstalled or moved to
>    another Apple account. Stop and tell me how to reconnect it; reconnecting
>    registers again with the same `client_name` and never reuses the old
>    `client_id`.
> 3. Speak MCP over `POST {my-url}/mcp`: `initialize` first (keep the
>    `Mcp-Session-Id` response header on later requests), then push content
>    with the `add_sources` tool. Each item: a **stable canonical `url`** (the
>    dedup key — same item must produce the same URL every run), `title`,
>    `source_type` (usually `"article"`), and the full plain-text `content`.
>    A meeting (`source_type: "meeting"`) also carries `occurred_at` — when it
>    took place, ISO 8601 — and `parent_group`, the recurring series it belongs
>    to (matched to an existing meeting group by id or title, case-insensitive,
>    or created); without them a meeting is dated by the moment it was pushed
>    and sits outside every series in the Meetings tab.
>    At most 50 items per call and ~1 MB per request; split beyond that.
>    Papers deliberately do not go through `add_source`: call
>    `import_connector_paper` with a public paper `url`, or call
>    `get_connector_inbox`, stage a local PDF in the returned plugin-specific
>    directory, and pass that path plus a stable public `source_url` to
>    `import_connector_paper`. This preserves the required Paper Metadata and
>    Source Content Cleanup steps.
> 4. Be idempotent: re-running must not duplicate anything (the server dedups
>    by URL and reports `already existed`). To refresh something that changed
>    at the service, re-push it with `"update_existing": true`; for a meeting
>    that also applies `occurred_at` and `parent_group`, so one re-push
>    corrects meetings first pushed without them.
> 5. Read the per-item results `add_sources` returns and fail loudly — print
>    anything that reports an error; never swallow failures.
> 6. Keep my service credentials (API key, cookies) local to the script. They
>    must never be sent to ForeverLM — ForeverLM only ever receives the
>    extracted text.
> 7. Keep the plugin's own state (tokens, per-item hashes, the last-run
>    watermark) in a SQLite file next to the script, mode `0600`, not in a JSON
>    file. A JSON blob is rewritten whole on every save, so an interrupted run
>    can truncate it and lose the refresh token along with the sync history.
> 8. Hold an exclusive lock for the length of a run, and exit immediately if
>    another run holds it. Where refresh tokens are single-use and rotate
>    (Read AI's do), two overlapping runs race on the same token and break the
>    chain for both. When the chain does break, report it and say which command
>    reconnects rather than failing silently.
>
> Note: ForeverLM's MCP URL only responds while the ForeverLM app is running
> on my Mac, so handle connection failures by skipping the run and trying
> again next time, not by erroring the schedule away. One exception: if the
> URL answers HTTP 502, 503 or 504 and `GET http://127.0.0.1:8522/mcp-url`
> (ForeverLM's own listener on this Mac, up only while it is connected)
> returns `{"url": …}` naming a different URL, my personal URL has moved.
> Save that URL, register there again under the same `client_name`, approve
> again, and carry on. A registration and its tokens belong to the URL they
> were made at, so never send them to the new one.

That's the whole contract. The assistant writes the script; you run it on
whatever schedule suits the material — a scheduled assistant task, `cron`,
launchd, or just "run it when I ask".

## Example use cases

These are worked examples of the recipe above, not product features. Your
assistant builds the plugin, it runs with your
credentials on your side, and you own it — we don't ship or support these as
extensions.

**Read AI meeting transcripts.** Fill the recipe in with: *"sync my Read AI
meetings into ForeverLM"*. Read AI's API uses OAuth 2.1 with rotating refresh
tokens (your workspace needs Downloads enabled under Workspace Settings →
Reports & Sharing). Have the plugin list recent ended meetings, fetch each
transcript, and push one source per meeting with `source_type: "meeting"`
semantics via `add_sources` — a stable URL per meeting id keeps re-runs
duplicate-free, `occurred_at` from the meeting's start time dates it, and
`parent_group` set to the series name (the title with tags like `[EF]` and
any trailing date stripped) files it inside its recurring meeting in the
Meetings tab. Name the plugin so it starts with "Read AI" (the example
registers as "Read AI Meetings"): ForeverLM then files its meetings under Read
AI and shows its health on the Read AI card. When the Meetings tab has Read AI
meetings and no plugin for them, its notice copies this recipe already
filled in for Read AI, with these notes attached — and since those meetings
arrived through a plugin once, the copy opens by asking your assistant to
find that plugin and reconnect it, and to build a new one only if none is
left.

**Anything with a feed.** Fireflies, Readwise highlights,
RSS — the shape is always the same: fetch with your credentials, extract plain
text, push with stable URLs. If you can curl it, it can be a plugin.

## Where your sources land

Plugin-added sources appear in your library like any other source, marked
with a plugin origin and the plugin's name. They join notebooks, the
Schedule, and reviews only when **you** (or your assistant, at your ask) put
them there — a plugin can never schedule its own content or push it into an
assistant's context.

## Removing a plugin

Two independent switches, both in **Plugins → Build Your
Own**, next to the plugin's name:

- **Remove Access**: the plugin's tokens stop working immediately; it would
  need your approval again to reconnect. Sources it added stay.
- **Remove Sources**: every source it added is dismissed and archived — and
  won't come back on its own. (An assistant can do the same via the
  `remove_connector_sources` tool.)

## FAQ

**Does my service password/API key go through ForeverLM?** No. Your plugin
holds the service credentials and only sends extracted text to ForeverLM.

**What if two plugins use the same name?** They'd share a label (and a
bulk-remove). Give each plugin a distinct `client_name`. A name that starts
with a meeting provider's brand — "Read AI …" or "Zoom …" — claims that
provider: its meetings file under it, and its health shows on that provider's
card.

**Can a plugin read what's in my library?** No. Ingest-only connections
can't read anything except server status, their private paper-staging path,
and the results of their own pushes (add results include the existing-source
id when a URL was already in your library).

**Why does it say the connection failed at night?** Your ForeverLM MCP URL is
served by the app on your Mac; if the app isn't running, plugins can't
reach it. They should simply retry on their next scheduled run.

**Can my personal URL change?** Rarely, but yes: it follows your Apple
account, so it changes if ForeverLM is signed in under a different one. The
old URL then answers "not running" for good. A plugin running on the same
Mac can ask ForeverLM for the current one at
`http://127.0.0.1:8522/mcp-url`, which answers only programs on that Mac and
only while ForeverLM is connected. It returns the URL and nothing else.
Plugins built from the recipe above follow the move on their own; you approve
them once more.
