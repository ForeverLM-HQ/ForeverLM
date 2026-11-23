---
layout: doc
title: ForeverLM vs Heptabase
description: How ForeverLM compares to Heptabase on pricing, AI credits vs your own AI key, data ownership, and learning workflow.
---

# ForeverLM vs Heptabase

Heptabase is a visual thinking tool: whiteboards and cards for mapping out complex topics, with PDF annotation, a Zotero workflow, and a growing credit-based AI layer including an AI tutor. It's one of the best sense-making canvases available. ForeverLM shares its local-first values, and it now has a Canvas too, but its centre of gravity is different: it tracks the sources you consume and verifies, through AI review, that you understood them. Its Canvas is where you lay out your own ideas over that library.

## At a glance

| | ForeverLM | Heptabase |
|---|---|---|
| **Price** | 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost | No free tier. Pro $107.88/yr; Premium $215.88/yr; Premium+ $647.88/yr (monthly billing higher) |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, for any model in Chat (free models cost nothing); or an AI subscription you already pay for, over MCP | Credit-metered: 100 credits/mo on Pro (Gemini only), 1,800 on Premium; no bring-your-own-key |
| **AI tutor** | Review with any MCP assistant or in-app Chat — no tier required | AI tutor requires Premium ($215.88/yr) |
| **Platforms** | Native macOS app (macOS 14+) | Mac, Windows, Linux, iOS, Android, web |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Local-first database; sync via Heptabase's AWS cloud (US, not end-to-end encrypted) |
| **Source ingestion** | Automatic: Safari reading list, Apple Podcasts, PDFs, papers, books, YouTube, X posts | Manual: PDF import, web clipper, YouTube transcripts, Zotero, Readwise |
| **Podcasts** | Follow shows, full episode transcripts | Not supported |
| **Canvas** | Ideas-first Canvas over the whole library: Ideas, regions inside regions, arrows, sources as evidence (in beta releases) | Mature card-first whiteboards: cards, sections, mind maps, nested whiteboards |
| **Spaced review** | Weekly Schedule + saved review history per source | On the roadmap, not shipped |
| **Export** | Files on your Mac; SQLite you can open | Strong: full Markdown + JSON export, automatic daily local backups |

*Pricing verified July 2026 (Heptabase's May 2026 price list) — check [heptabase.com/pricing](https://heptabase.com/pricing) for current numbers.*

## Pricing: credit tiers vs your own AI key

Heptabase has **no free tier** and its AI is credit-metered. The plan most learners would want — unlimited PDFs plus the AI tutor and non-Gemini models — is Premium at **$215.88/yr billed annually** ($23.99 month-to-month). Heavy AI use points to Premium+ at $647.88/yr. The credits are Heptabase-denominated, they reset every month whether you used them or not, and there's no bring-your-own-key escape from the meter.

ForeverLM is **7 days free, then $19 once**, with no subscription and no tiers to pick between: paying gets the whole app, with every model on your own OpenRouter key. Two ways to use AI, mixable: any model in the in-app Chat on your OpenRouter key, billed by OpenRouter at its cost with nothing added by ForeverLM (free models cost nothing); or the Claude, ChatGPT, Gemini, or Grok subscription you already pay for, connected over MCP. Your subscription covers the inference, and ForeverLM charges nothing per request. The in-app route also spends a little on background work (transcript cleanup, paper metadata extraction), billed the same way, with the model configurable per task. The app records every token and shows costs to the cent.

The three-year comparison is lopsided in a way that's worth stating plainly: Heptabase Premium is ~$648 before you've done anything, while ForeverLM is $19 once, MCP included, plus whatever OpenRouter bills your own key for what you use (nothing on free models).

## Where Heptabase is better

- **A mature, card-first whiteboard.** Heptabase is built around its whiteboards: years of polish, cards you write once and place on many boards, nested whiteboards, mind maps, and journals. ForeverLM's Canvas is newer (in beta releases today) and ideas-first: your Ideas, regions and arrows on one plane over the library, with sources hanging off them as evidence, rather than a board of cards you write.
- **Cross-platform.** Mac, Windows, Linux, iOS, Android, and web. ForeverLM is Mac-centered, with an iPhone app and a web library for reading and listening.
- **Note-taking depth.** Heptabase is a full PKM app; ForeverLM deliberately isn't one.
- **Academic PDF workflow.** Annotation, OCR parsing (Premium), and Zotero integration are strong for paper-heavy research.
- **Exemplary export.** Automatic daily Markdown + JSON backups on your own disk set the standard for exit-friendliness.

## Where ForeverLM is better

- **The retention loop exists today.** Heptabase's spaced repetition has been on the roadmap for years and remains unshipped; its AI tutor is a guided-session feature on the $215.88/yr tier. ForeverLM ships the whole loop (weekly Schedule, review, per-source understanding history) in the one app, with no tier to climb. See [Why Quizzing?](/why-quizzing)
- **No credit tiers.** Credits are a second subscription inside the subscription, denominated in Heptabase's own currency and refilled monthly whether you need it or not. ForeverLM uses real provider costs instead: in-app Chat runs on your own OpenRouter key at OpenRouter's cost with nothing added, or on free models for nothing; or drive it over MCP from an assistant you already subscribe to. No feature is gated behind which tier you're on.
- **Sources arrive automatically.** Heptabase ingestion is pull-based: clip, import, drag. ForeverLM discovers sources from your Safari reading list, Apple Podcasts follows, and reference managers.
- **Podcasts.** Full episode transcripts as first-class study sources; Heptabase has no podcast pipeline.
- **Model freedom at every price.** Heptabase locks non-Gemini models behind Premium. ForeverLM works with Claude, ChatGPT, Gemini, or Grok from day one.
- **Sync through your own cloud.** Both apps are local-first, but Heptabase syncs through its US-based AWS (readable by the vendor); ForeverLM syncs through your personal iCloud account, and its servers never store your library.
- **A canvas wired to its sources.** On ForeverLM's Canvas a paper can show only its figures, a passage card opens the paper at that passage, a box drawn around a figure in the Reader drags straight onto the board, and Claude or ChatGPT can lay a canvas out over MCP.

## Which should you choose?

Choose **Heptabase** if your bottleneck is *making sense* of complex material and you think in cards you write and arrange: its whiteboards are the most mature. Or if you need Windows, Linux, or Android.

Choose **ForeverLM** if your bottleneck is *remembering* what you consume: you want automatic source capture (podcasts included), a scheduled review loop that exists today, and AI costs that track what you actually used instead of climbing credit tiers.

Some people use both: Heptabase to map a topic while learning it, ForeverLM to track the sources and verify the understanding sticks.
