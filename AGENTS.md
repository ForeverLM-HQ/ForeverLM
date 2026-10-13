# AGENTS.md — ForeverLM

ForeverLM is a learning app for Mac, iPhone and the web: learners build notebooks of sources (papers, books, articles, podcasts, videos), chat with them, and are quizzed until they can explain an idea in their own words.
These rules apply to human contributors and to coding agents alike. Each rule carries its reason in one line; if a rule and your change disagree, say so in the change.
The app is SwiftUI (macOS and iOS), with a web library, a hosted MCP gateway, shared sync code in `schema/`, and user docs in `docs-site/`.

## Names

- **The product is ForeverLM.** Environment variables use the `FOREVERLM_` prefix. The retired name `FeynmanLM` survives only in the one-time identity adoption (`ForeverLMApp/Shared/Services/Storage/LegacyIdentityAdoption.swift`) that moves an existing library; anywhere else, rename it in the same change. Why: a second live name strands users' data and confuses support.
- **What the app runs is a *review*** (`ReviewSession`, `ReviewSessionManager`, `review_sessions`, `start_review_session`). The retired method name must not return in any identifier, string, comment, prompt or doc.
- **A notebook is a *notebook*, in code as well as on screen.** Never use `project` to mean a notebook (identifier, table, column, MCP name, string, comment, doc). Intentional exceptions are the migrations and one-time adoptions, names that stored records or hash inputs still depend on, history, and the word's other senses (the Xcode project, `ProjectionApply.project`). Why: one word per concept, everywhere.
- **A Page is what a learner sees; the code says doc.** `Artifact` is the internal entity, the `*_doc` MCP tools, `doc_id`, the `foreverlm://doc/<id>` address, accessibility identifiers and test names keep the old word. Do not write "Doc" in any learner-facing string, and do not rename those identifiers piecemeal (a rename is its own change). `Google Docs` and documentation keep the word.
- **Values that cross a boundary are named from the identifier, never from a UI word.** What an MCP client, a stored record or a sync payload reads comes from `rawValue` or a literal, so a display rename cannot change a contract.
- **Use made-up names in tests, fixtures and docs** (Zara Holt, Acme Lab, example.org), never a real person, workspace or account.

## Engineering principles

- **Fix root causes, not the reported example.** A failure is evidence about a broken general contract. Find the mechanism and the invariant, use the report as a regression fixture, repair the shared pipeline, and verify adjacent cases. No branch for one provider, domain, file or record unless it exposes a genuinely distinct protocol, with the reason documented at the branch. If special cases start to accumulate, redesign the abstraction.
- **A bug you run into along the way is yours to fix.** Reproduce it first and rule out stale state; fix it in the same change or split it into its own when it is too large, and say which in the change description.
- **Event-driven over polling.** Freshness comes from user or system events (activation, a tab opening, scroll-to-top, remote-change notifications). A timer may exist only as a low-frequency backstop. Event-triggered syncs are silent, cooldown-limited, and republish UI state only when something changed.
- **No fallbacks that mask failure.** Surface errors and fail loudly. This holds especially for AI features: no heuristic grading, no substitute feedback, no silent retry on another model or provider.
- **No invented default values in Swift.** If a value is missing and the code cannot know it, surface that; do not make one up.
- **Do not leave dead config.** Delete an `AITask` case, setting or flag together with the feature it served; a setting that silently does nothing is a bug.
- **Multiple agents work in this repo at once.** Do not undo changes you do not recognize; prefer forward progress over rollback. Commit only your own files, never sweep a sibling's half-finished work into your commit, and never add untracked scratch directories.
- **Check the repo, not your memory, before claiming a rule is stale.** Prefer `git log`, the code and tests over prose.

## Storage

- **Persistence is SQLite (`knowledge.db`), never JSON files.** Why: one transactional store that sync, migrations and queries can rely on.
- **Never delete, replace, reset or recreate `knowledge.db` to make a build work.** Rebuilds and updates keep the user's database.
- **Reads of derived or evicted files are not free.** The library lives in iCloud Drive; a synchronous read of an evicted file blocks until it downloads.
- **Per-member state never lives in shared content records.** Reading state, highlights, cards, schedule and similar belong to the member's own records, keyed by the same ids as the shared content, with no foreign key that lets deleting content cascade into a member's state.

## Migrations

Startup migrations are the delivery mechanism for schema changes; other people's databases are only fixed by what ships in the build. A hand-typed `sqlite3` fix repairs one machine.

- **Forward-only, versioned, transactional.** A database whose `PRAGMA user_version` is older than the build runs only the forward migration inside `BEGIN IMMEDIATE`; the version stamp is the last write; any failure rolls everything back. A current database takes the read-only fast path: one version read, nothing else.
- **No unconditional work at launch.** Repairs, backfills and cleanups are gated on the version so they retire after one run.
- **Off-main, always.** Migration SQL runs through the storage actor. The window paints and stays interactive: no synchronous waits, semaphores, dispatch barriers or `.wait()` on the main thread, and no main-actor `await` that gates first paint on the migration.
- **Invisible to the user.** A migration may do DDL and bounded, set-based metadata changes only. It must not loop over an unbounded table, parse or hash content, touch FTS or embeddings, access files, call the network, CloudKit or AI, or do anything proportional to library size. Put expensive backfills in a versioned, durable SQLite queue: enqueue transactionally, commit the schema, publish the existing library, then drain off-main in bounded, idempotent, resumable batches.
- **Never make an intact library look empty.** If a rare incompatible schema needs a blocking gate, show an explicit updating state with progress and errors, never the ordinary empty-library state.
- **Check query plans.** Run `EXPLAIN QUERY PLAN` on migration SQL over large tables; a table scan inside a per-record loop is a release blocker.
- **Production-shaped proof before a schema bump.** Forward-migration tests from every supported released schema; rollback tests proving the original version and data survive a failure; parity checks for sources, relationships, `sync_metadata` and `sync_changes`; a large-fixture scale test with its measured wall-clock cost stated in the commit message (well under a second on a library the size of the largest real one, or defer the work); and a launch assertion that sources stay visible while deferred work is pending. Fixtures carry the real historical table shape: never create today's schema and lower `user_version`.
- **Views are code-owned derived state** and may be re-derived when their stored definition drifts from the build's.
- **Direct SQL changes to synced records also update the sync bookkeeping.** Under generation 1 that is `sync_metadata` and `sync_changes`; under generation 2 the generated outbox triggers record changes.

## Responsiveness

A beachball (main thread blocked) is always a bug and a release blocker, on par with a crash or data loss.

- **The main actor only gathers UI state, runs lightweight updates, and publishes results.** Never file I/O, SQLite scans, CloudKit or iCloud path discovery, network or AI calls, parsing, indexing, deduplication or source discovery there. Split long workflows into a small main-actor snapshot, nonisolated processing, and a small main-actor publish.
- **SwiftUI `body` and computed properties used by views are pure and fast.** No reading files, querying SQLite, resolving iCloud containers (`FileManager.url(forUbiquityContainerIdentifier:)`), parsing documents or normalizing large lists while rendering.
- **App startup is read-only and fast.** Sync and discovery start after launch and never block the main actor.
- **Reader progress (PDF pages, EPUB locators, transcript offsets) is debounced** and persisted off-main; scroll and page callbacks only update lightweight UI state.
- **Diagnosing a stall:** `UIResponsivenessMonitor` writes a process sample to the app's Diagnostics folder whenever the main thread stalls for more than a second. Read the main-thread stack there first.
- When adding a workflow, ask of every step whether it can block; if so, move it off-main and surface progress or errors through existing UI state.

## LLM features

- **Every LLM step is an `AITask` the user can configure.** No call hardcodes a model or provider. A task gets its model from `KeychainService.resolveConfig(for:)`, is selectable through `set_ai_task_settings`, has a `displayName` and `description`, is listed in `advancedTasks`, and call sites receive the resolved `AITaskConfig` and never name a model. A model-id literal outside `AIModelDefaults` and `KeychainService` is a bug (`ForeverLMApp/scripts/check_ai_model_routing.sh` runs in the build and enforces it). A pinned exception needs a capability reason, a comment at the call site, and still takes the model from settings.
- **Prefer an LLM call over string parsing for human-written text.** Regexes over titles, file names, notes or folder conventions converge on a pile of special cases; the tell is the second or third special case. Add an `AITask`, a prompt in `Prompts.swift`, and a batched method on `AIService`; one call per import beats one call per item.
- **Never let an LLM decide identity.** Primary keys, source URLs, grouping and dedup keys, and sync identity stay deterministic code, so a slow, failed or non-reproducible call cannot reshuffle stored data. Parse structure (dates, ids, extensions); ask the model for meaning (topic, presenter, summary). `StudioViewModel+Meetings.swift` is the reference shape.
- **AI failures surface.** No heuristic grading, no fallback feedback, no review status inferred when recording failed.
- **A source reads the moment it is added.** Save it readable first (a PDF as its file, a book as one entry over its file, text as its raw text), then run its model steps (metadata, classification, cleanup, OCR, chapter splits) in the background, behind a local durable queue when the work has to outlast a quit. A background failure or the learner's Stop never removes the source or blocks reading it. (product owner, 2026-10-13: "for all sources if we upload it, we should IMMEDIATELY be able to already read it; even if some background cleanup work then needs to happen in the background afterward")
- **Prompt caching is a request invariant.**
  - Every text request carries a stable per-conversation `session_id`, namespaced by the authenticated user.
  - Keep the stable system and source head separate from volatile digest or retry context; a model's immutable system instruction takes its volatile tail in a later user message.
  - Serialize request JSON through `AIService.stableJSONBody`, never bare `JSONSerialization`: Swift dictionary order is seeded per process, so a re-encoded tool schema misses the cache after a relaunch.
  - Never mark a prefix that cannot be reused: a cache write costs more than an unmarked read, so gate markers on `AIService.systemPromptIsCacheable`.
  - Record both cache reads and cache writes from usage.
- **A model pick takes effect only after a short test run of its work passes** (`AIModelQualification`). A refusal keeps the previous pick; a failed test never removes the model from its list.

## Managed AI routing

- **Every model goes through OpenRouter.** Text, images, video, speech and transcription each use OpenRouter's own API and model directories, listed live so a new model appears without a code change. There is no first-party provider route (no direct Anthropic, OpenAI, Gemini, xAI or Meta adapter, no speech-to-speech route). A feature OpenRouter cannot serve is unavailable; say what is missing instead of adding a route.
- **A request names exactly one model and one route.** No provider is an automatic fallback for another, and a failed request is never silently retried on a different model.
- **Managed off-device requests go app, then the managed proxy (`ai.foreverlm.com`), then the route.** A learner may bring their own OpenRouter key, which pays for every model ForeverLM uses.
- **Secrets never appear in source, in the app, or in client requests.** Long-lived provider credentials live only server side. Unknown paths, models, prices, tiers and missing cost components fail closed.
- **Ledger invariants** (what counts as a billable record, record-before-validate) are tested in the app's AI usage tests; read them before changing accounting.

## Sync and parity

- **Cross-device state parity is a correctness requirement.** Two devices on the same account present the same sources, notebooks, schedule and chats, and the same relationships between them. A record that syncs but arrives without the foreign keys that give it meaning is a sync bug (a chat that loses its goal link vanishes from its notebook and reads as data loss).
- **When adding or changing a synced entity, verify the whole round trip:** the outbound select, the payload struct and its `CodingKeys`, the inbound upsert's column list and its `DO UPDATE SET` clause, the iPhone and web equivalents, and (generation 2) the projection's `encodeRows` and `apply`, its feeds, and the iPhone and web writers. Every column that carries identity or a relationship appears in all of them.
- **New payload fields are optional (`decodeIfPresent`)** so older devices keep decoding. The web never writes a field the Mac does not already have, because the Mac's Codable structs drop unknown keys.
- **Deliberate asymmetries** (local-only, regenerable, intentionally one-way entities) are documented with the reason where the sync contract lives; silence means the omission is a bug.
- **CloudKit schema comes first.** `schema/cloudkit-schema.json` is the single source of truth; regenerate everything derived from it with `node scripts/schema/generate.mjs` and never hand-edit `schema/generated/` or `schema/js/schema.generated.*`. A new synced entity is a record type or field there, gets a `RecordProjection` on the Mac (`ForeverLMApp/Shared/Sync/Projection/`) plus matching iPhone and web reads and writes, and passes the shared vectors in `schema/` in both cores. A new field needs no CloudKit deploy; a new record type does, and the maintainers do that before a build that writes it ships. `npm run schema:check` (in `docs-site/`) fails when the generated files are stale.
- **Teams are spaces.** A team is one CloudKit zone shared zone-wide; a source has the same id in every zone; per-member state never enters a space record (`SpaceWriteGuard` in Swift and JS enforces it); sharing a notebook into one's own space moves it, into someone else's copies it. On an activated store the generated outbox triggers record changes, so new paths never call `markRecordChanged`, never name a zone, and never write a registered table with `INSERT OR REPLACE` (use an upsert).
- **Desktop and web parity is mandatory inside the web's boundaries.** A user-visible change to a surface both clients have includes both in the same change, and is not complete until both are implemented and verified. Surfaces that intentionally stay Mac-only (ingestion, local audio, scheduled runs on the learner's Mac) must not be described as available in the browser. The web app is a separate implementation, so a browser check verifies web code and synced data, not Swift.

## MCP

- **MCP is a product surface, not an afterthought.** Every setting a learner can change is also settable through `get_app_settings` / `set_app_setting` or a dedicated tool pair; diagnostics and switches that have no pane are marked "(no pane)" in the catalogue so an assistant does not send the learner looking.
- **Adding a tool:** register it in the MCP registry (`ForeverLMApp/MCP/`), regenerate the catalogue in `workers/shared/mcp-tools.generated.json`, update the desktop-only or public tool lists in `workers/shared/public-mcp-tools.ts` as needed, and document it in `docs-site/mcp-tools.md`. No top-level `anyOf` in a tool's input schema.
- **MCP writes go through the existing storage APIs** so SQLite and the sync bookkeeping stay consistent.
- **Return structured, stable output** (source ids, goal ids, dates, completion state, linked review status) and validate input against current state before mutating. A review recorded over MCP preserves the transcript, not only metadata.
- **Do not bypass the plugin to answer a plugin question.** When asked to use the ForeverLM MCP tools, use them end to end; surface and fix a failure rather than reading `knowledge.db` as a workaround. Direct database inspection is for when it is explicitly requested.

## UI design

The app is minimalist, and ChatGPT's app is the reference for quiet chrome. Resist explanatory copy, helper text, subtitles and onboarding hints where the control already says what it does. Delete copy before adding copy.

- **Words are as few as the controls.** Prefer labels, icons and layout over paragraphs. Empty states are one line at most, or just the action. No small-caps line above a pane that repeats the sidebar. A description or caption is one clause, kept where it states a cost, a privacy consequence or an action the learner must take.
- **A top bar holds only what its pane cannot do without:** the way back and title, one primary action, state that is happening now and asks for something, a `⋯` menu for the rest, and the close ×. Everything else is reached where it acts: on hover, on a selection, from the `⋯`, a context menu, the menu bar or a shortcut. Before adding a glyph to a top bar, say which of those it is.
- **Every list of the learner's things wears the same head.** Build it from the place-chrome kit in `ForeverLMApp/App/SpaceBrowseView.swift` (`SpacePlaceHeader`, the dark pill action `SpaceDarkPillButton` / `SpaceDarkPillMenu`, `SpaceScopePill`, `SpaceEmptyLine`, `spacePlaceColumn()`). Never draw a list's own title, search field or `.borderedProminent` "New" button; if the kit lacks something, add it to the kit.
- **Settings holds only what a learner changes.** A knob with one realistic value, a diagnostic, or a switch for an unfinished feature stays out of the window and remains reachable over MCP. A new feature adds a section to an existing pane rather than a new pane; a new kind of model is the one exception and gets a row under AI Models. Logs are not settings.
- **The iPhone app lays out by size classes, never by the device.** Decide from `horizontalSizeClass`, `verticalSizeClass` and the width the view is given, re-read as they change. Never read `UIScreen.main`, `userInterfaceIdiom`, `UIDevice.current.orientation`, or build a window from a frame; use `displayScale` and `view.window?.windowScene`, and never assume equal left and right safe-area insets. `ForeverLMApp/scripts/check_ios_adaptive_layout.sh` fails the build on those names. A layout that needs an iPad's room asks for regular width and regular height.
- **Every button lights up under the pointer.** Use `.buttonStyle(.hoverWash)` (or `.hoverWash(cornerRadius:inset:opacity:)`, `.hoverWash(in:)`) from `ForeverLMApp/App/HoverHighlight.swift`; never leave a button on `.plain` or `.borderless`, which paint no hover chrome. The wash is the click target, not a rectangle drawn near it. For a `Menu` or tap-gesture row use `.hoverHighlight(...)`. The exception is a button inside a row that already paints its own hover background. In the titlebar band a SwiftUI `Button` or `Menu` neither lights up nor receives clicks (AppKit hands the press to the window drag); use `TitlebarBandButton` there. A new icon button is not done until you have hovered it and seen the square, including controls that appear only on row hover.
- **Text that speaks for itself is not selectable.** The main windows enable `.textSelection(.enabled)`, which hosts every `Text` in AppKit text elements; a `Text` that also has `.accessibilityLabel`, `.accessibilityValue` or `.accessibilityHint` then has two owners and can overflow the stack inside the accessibility node on macOS 27. Put `.textSelection(.disabled)` on any `Text` or `Label` before giving it an accessibility label or value (timestamps, badges, status lines, error chips). Labels on a `Button` or on a container using `.accessibilityElement(children:)` are fine. Verify with a deep accessibility walk of the live window, not with a build.
- **A new first-class surface gets a short design note** in the user docs or the PR: its hierarchy, primary controls and parity across clients.

## Swift traps

- **Never build a tuple around a `try await` inside a task closure; bind the awaited value first.** `return (id, .success(try await work()))` and `(index, try await work())` inside `group.addTask` or `Task` miscompiled in Release builds on Swift 6.3 (the element evaluated before the suspension came back empty); keep the rule until a newer toolchain is shown to be clean. Write `let value = try await work()` and then `return (id, value)`. Debug builds and unit tests never see it, so a Release-only crash in a task group is the first suspect.
- **`JSONSerialization` bridges `0` and `1` so that they pass `is Bool`.** Check numeric-ness before booleanness when decoding loosely typed JSON.
- **`"#` ends a raw string literal started with `#"`**; a payload containing that sequence needs more hashes.
- **`await` inside the right-hand side of `??` does not compile** (it is an autoclosure). Resolve the awaited value on its own line first.
- **Swift dictionary iteration order is per-process seeded.** Never serialize a dictionary for hashing, caching or comparison without sorting keys (use `AIService.stableJSONBody` for requests).
- **Do not write `UserDefaults` while holding a lock**, and run maintenance work at `.utility` priority.
- **The Swift toolchain is pinned** in `.swift-version` and `ForeverLMApp/WebAssembly/README.md` (the website's WebAssembly core builds against it); do not bump it as a side effect.

## Project structure

| Path | Purpose |
|------|---------|
| `ForeverLMApp/App` | macOS app: views, window shell, Studio surfaces |
| `ForeverLMApp/Shared` | Code shared by macOS, iOS and extensions: models, services, storage, sync, view models |
| `ForeverLMApp/iOS`, `iOSShare`, `iOSWidget` | iPhone and iPad app, share extension, widget |
| `ForeverLMApp/MCP` | The in-app MCP server, tools and OAuth |
| `ForeverLMApp/Web`, `WebAssembly` | Web renderers embedded in the app (editor, canvas) and the WebAssembly core |
| `ForeverLMApp/UnitTests`, `iOSUnitTests`, `UITests` | Swift Testing and XCTest targets |
| `ForeverLMApp/scripts` | Build-phase checks and project tooling |
| `ForeverLMApp/project.yml` | XcodeGen definition of every target |
| `schema/`, `scripts/schema/` | CloudKit schema source of truth, generated tables (Swift and JS), shared test vectors |
| `workers/shared` | Server-side code shared between workers (generated MCP tool catalogue) |
| `plugins/` | The ForeverLM plugin and its skills |
| `docs-site/` | User documentation (VitePress), published at docs.foreverlm.com |

- **Never hand-edit `ForeverLMApp/ForeverLM.xcodeproj/project.pbxproj`.** It is generated from `ForeverLMApp/project.yml` by XcodeGen and committed so a fresh clone builds without XcodeGen. After changing `project.yml`, or after adding a Swift file under a directory `project.yml` already lists, run `ForeverLMApp/scripts/sync_project.sh`; it regenerates the project, says when something had drifted, and repairs it. A stale project builds without complaint and silently omits what `project.yml` gained.
- **Keep the checkout outside iCloud-synced folders** (not under `~/Documents`, `~/Desktop` or any synced directory). iCloud Drive has restored an older generated project file over a fresh one and left conflict copies behind.
- **Never delete DerivedData as a fix.** It does not cure errors and forces a full rebuild; find the actual cause.
- **Local-only config stays local.** `.env` and generated secrets files are gitignored; never commit credentials, tokens, account identifiers or signing identities, and never paste one into an issue, a commit message or a test.

## Verifying changes

Pick the narrowest check that can catch the bug, and say which you ran.

| Change | Verification |
|---|---|
| Comments, docs, copy strings, logging | Read the diff. |
| A pure function or predicate with its own tests | That one suite. |
| UI or view code with no logic change | Build the affected target; hover and look at what you changed. |
| New behavior in a service or view model | The suites covering it, plus the tests you added. |
| Storage, migrations, sync, source identity, the ingestion pipeline | The whole `ForeverLMMacUnitTests` target; required for schema work. |
| `schema/` or `scripts/schema/` | `node scripts/schema/generate.mjs`, then `npm run schema:check` in `docs-site/`. |
| `docs-site/` | `npm run audit` (regenerates `llms-full.txt`, checks the docs index and screenshot manifest) and `npm run build`, both in `docs-site/`. |
| iPhone code | An iOS Simulator build and runtime check; a macOS build alone proves nothing for `ForeverLMApp/iOS`. |
| The page editor (`ForeverLMApp/Web/ArtifactEditor`) | `npm test` and `npm run e2e` there (once: `npx playwright install webkit`). The browser tests type into the editor in WebKit, the app's engine, with a host that records every message; `e2e:corpus` opens and saves every page stored on this Mac (read only), `e2e:budget` times keys on a long page. No Xcode build. |

- **The scheme is `ForeverLM (macOS)`** (and `ForeverLM (iOS)`), shared and tracked; `Package.resolved` is tracked so a fresh clone resolves the same pins. Run `build-for-testing` once, then `test-without-building` per iteration; the build step is the cost.
- **`-only-testing:ForeverLMMacUnitTests/<Name>` takes the Swift type name**, not the `@Suite("…")` display string.
- **A test filter that matches nothing passes.** `xcodebuild` exits 0 with `Executed 0 tests, with 0 failures`, indistinguishable from success at a glance. Confirm tests actually ran (a non-zero executed count, or `✔ Test "…" passed`) before believing a green result.
- **Judge failures against a baseline, not a count.** The suite carries some failures that need network access or a signed-in account, and a few intermittent PDF-extraction fixtures. Compare failing test names against a run of the parent commit; when a failure looks unfamiliar, run that suite alone on the parent before assuming you caused it. If a failure only reads like a credential or network problem, check whether the call has an injection point the test simply did not use.
- **Finish a feature by watching it run**, not by watching it compile: open the surface, take the action a learner would, and report what you observed. Build with code signing enabled when verifying anything that needs an account (Sign in with Apple, managed AI, sync); an ad-hoc build has no entitlements, and nothing that needs an account or a synced record can be verified in it. Use `CODE_SIGNING_ALLOWED=NO` for test bundles only.
- **Verify onboarding in a fresh-install build**, not a seeded library, which can only show what a returning learner sees.
- **Do not run real-network or paid-API tests by default.** Live API tests are opt-in and need your own key.
- **Include a `Verify:` line in the commit message** when a change needs a check you did not run (the suites to run, the behavior to watch, where to find it). A change that needs no build says `Verify: none (no Swift)`.

## User documentation

User docs live in `docs-site/` (VitePress, published at docs.foreverlm.com) and describe what a learner sees, in the app's own words.

- **A user-visible change updates the matching page in `docs-site/` in the same change**, including the MCP tool list in `docs-site/mcp-tools.md` when tools change. A change that makes a doc inaccurate is incomplete.
- **Say "Page" and "notebook" and "review"**, never the retired words (see Names). Keep screenshots current: `docs-site/screenshots.json` lists them and `docs-site/copy-screenshots.sh` copies them in.
- **Keep status honest.** Describe shipped behavior as current and a proposal as a proposal; never document an unbuilt mockup as the current UI.
- **Regenerate derived docs files** (`docs-site/public/llms-full.txt` via `npm run llms`) when pages change, and run `npm run audit` in `docs-site/` before sending the change.
- **Do not name people, private workspaces or real accounts** in code, comments, tests, fixtures or docs; say "ForeverLM" where the publisher is meant, and state a product decision as a rule without attribution.

## Commits

- **Every ForeverLM commit and GitHub write must use the `foreverlm-admin` GitHub account.** Before committing, pushing, merging, or otherwise changing this repository on github.com, run `gh auth status` and verify that `foreverlm-admin` is the active account. Never perform those actions with any other account; switch first.
- **Commit messages explain why**, name the area touched, and state the measured cost for any migration.
- **Never commit generated scratch output, local databases, `.env`, keys or credentials.**
- **Keep unrelated work in separate commits**, each with its own message; do not bundle a refactor into a bug fix.
