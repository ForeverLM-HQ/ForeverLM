---
layout: doc
title: ForeverLM vs Heptabase
description: How ForeverLM compares to Heptabase on pricing, AI credits vs your own AI key, data ownership, and learning workflow.
---

# ForeverLM vs Heptabase

Heptabase is a visual thinking tool: whiteboards and cards for mapping out complex topics, with PDF annotation, a Zotero workflow, and a growing credit-based AI layer including an AI tutor. It's one of the best sense-making canvases available. ForeverLM shares its local-first values but works the other way around: instead of you arranging knowledge spatially, it tracks the sources you consume and verifies — through review-style AI review — that you understood them.

## At a glance

| | ForeverLM | Heptabase |
|---|---|---|
| **Price** | Free to download and free over MCP; built-in AI needs a plan ($4/mo, or $19/yr for early believers) and your own OpenRouter key | No free tier. Pro $107.88/yr; Premium $215.88/yr; Premium+ $647.88/yr (monthly billing higher) |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, plus a ForeverLM plan ($4/mo, or $19/yr for early believers) for any model in Chat; or free over MCP from an AI subscription you already pay for | Credit-metered: 100 credits/mo on Pro (Gemini only), 1,800 on Premium; no bring-your-own-key |
| **AI tutor** | review with any MCP assistant or in-app Chat — no tier required | AI tutor requires Premium ($215.88/yr) |
| **Platforms** | Native macOS app (macOS 14+) | Mac, Windows, Linux, iOS, Android, web |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Local-first database; sync via Heptabase's AWS cloud (US, not end-to-end encrypted) |
| **Source ingestion** | Automatic: Safari reading list, Apple Podcasts, PDFs, papers, books, YouTube, X posts | Manual: PDF import, web clipper, YouTube transcripts, Zotero, Readwise |
| **Podcasts** | Follow shows, full episode transcripts | Not supported |
| **Spaced review** | Weekly Schedule + saved review history per source | On the roadmap, not shipped |
| **Export** | Files in your iCloud Drive; SQLite you can open | Strong: full Markdown + JSON export, automatic daily local backups |

*Pricing verified July 2026 (Heptabase's May 2026 price list) — check [heptabase.com/pricing](https://heptabase.com/pricing) for current numbers.*

## Pricing: credit tiers vs your own AI key

Heptabase has **no free tier** and its AI is credit-metered. The plan most learners would want — unlimited PDFs plus the AI tutor and non-Gemini models — is Premium at **$215.88/yr billed annually** ($23.99 month-to-month). Heavy AI use points to Premium+ at $647.88/yr. The credits are Heptabase-denominated, they reset every month whether you used them or not, and there's no bring-your-own-key escape from the meter.

ForeverLM is **free to download**, and there are no tiers to pick between: built-in AI needs a ForeverLM plan ($4 a month, or $19 a year while the early-believer offer lasts) and your own OpenRouter key, and every plan gets every model. Two ways to use AI, mixable: any model in the in-app Chat on your OpenRouter key, billed by OpenRouter at its cost with nothing added by ForeverLM; or the Claude, ChatGPT, Gemini, or Grok subscription you already pay for, connected over MCP at no charge from ForeverLM — your subscription covers the inference, and reading and writing your library is free. The in-app route also spends a little on background work — transcript cleanup, paper metadata extraction, search embeddings — billed the same way, with the model configurable per task. The app records every token and shows costs to the cent.

The three-year comparison is lopsided in a way that's worth stating plainly: Heptabase Premium is ~$648 before you've done anything, while ForeverLM is $0 over MCP, and its built-in AI costs ~$140 at $4 a month (or $57 at the early-believer $19 a year) plus whatever OpenRouter bills for what you use.

## Where Heptabase is better

- **Visual sense-making.** Whiteboards, spatial card arrangement, and journals are a genuinely different way to work through hard material. ForeverLM has no canvas.
- **Cross-platform.** Mac, Windows, Linux, iOS, Android, and web. ForeverLM is Mac-only.
- **Note-taking depth.** Heptabase is a full PKM app; ForeverLM deliberately isn't one.
- **Academic PDF workflow.** Annotation, OCR parsing (Premium), and Zotero integration are strong for paper-heavy research.
- **Exemplary export.** Automatic daily Markdown + JSON backups on your own disk set the standard for exit-friendliness.

## Where ForeverLM is better

- **The retention loop exists today.** Heptabase's spaced repetition has been on the roadmap for years and remains unshipped; its AI tutor is a guided-session feature on the $215.88/yr tier. ForeverLM ships the whole loop — weekly Schedule, review, per-source understanding history — with no tier to unlock, and free over MCP. See [Why Quizzing?](/why-quizzing)
- **No credit tiers.** Credits are a second subscription inside the subscription, denominated in Heptabase's own currency and refilled monthly whether you need it or not. ForeverLM uses real provider costs instead: in-app Chat runs on your own OpenRouter key at OpenRouter's cost with nothing added, beside a plan ($4/mo, or $19/yr for early believers), or nothing at all if you drive it over MCP from an assistant you already subscribe to. No feature is gated behind which tier you're on.
- **Sources arrive automatically.** Heptabase ingestion is pull-based: clip, import, drag. ForeverLM discovers sources from your Safari reading list, Apple Podcasts follows, iCloud folders, and reference managers.
- **Podcasts.** Full episode transcripts as first-class study sources; Heptabase has no podcast pipeline.
- **Model freedom at every price.** Heptabase locks non-Gemini models behind Premium. ForeverLM works with Claude, ChatGPT, Gemini, or Grok from day one.
- **Sync through your own cloud.** Both apps are local-first, but Heptabase syncs through its US-based AWS (readable by the vendor); ForeverLM syncs through your personal iCloud account, and its servers never store your library.

## Which should you choose?

Choose **Heptabase** if your bottleneck is *making sense* of complex material and you think spatially — or you need Windows, Linux, or Android.

Choose **ForeverLM** if your bottleneck is *remembering* what you consume: you want automatic source capture (podcasts included), a scheduled review loop that exists today, and AI costs that track what you actually used instead of climbing credit tiers.

Some people use both: Heptabase to map a topic while learning it, ForeverLM to track the sources and verify the understanding sticks.
