---
layout: doc
title: ForeverLM vs Recall
description: How ForeverLM compares to Recall (recall.it) on pricing, data ownership, AI model choice, and how each verifies what you've learned.
---

# ForeverLM vs Recall

Recall (recall.it, formerly getrecall.ai) is a self-organizing AI knowledge base: save articles, YouTube videos, PDFs, and podcasts; get AI summaries, auto-tagging, a knowledge graph, and spaced-repetition quizzes. It's the closest competitor to ForeverLM in spirit — both are local-first, both cover many source types, both take retention seriously. The differences are in pricing model, platform, and how deep the review goes.

## At a glance

| | ForeverLM | Recall |
|---|---|---|
| **Price** | Free, MCP included; AI on your own OpenRouter key at cost | Free tier (10 AI summaries/mo); Plus $120/yr; Max $456/yr (billed yearly) |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, for any model in Chat (free models cost nothing); or an AI subscription you already pay for, over MCP | Included in subscription; model auto-selected on Plus, model choice only on Max |
| **Platforms** | Native macOS app (macOS 14+) | Web app + browser extensions, iOS, Android — no native desktop app |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Local-first on device; sync via Recall's cloud (Google Cloud, EU) |
| **Source ingestion** | Automatic: Safari reading list, Apple Podcasts follows, PDFs, papers, books, YouTube, X posts | Manual saves via extension/app: articles, YouTube, PDFs, podcasts, X, Reddit |
| **Review method** | Cards you keep from your sources on a spaced schedule, and review dialogue with an AI tutor that reads the full source | Spaced-repetition quizzes (question/answer style) — paid tier only |
| **MCP / assistant access** | Full MCP control surface: search, schedule, run and save review sessions | MCP + API access (retrieval) |
| **Export** | Files on your Mac; SQLite you can open | Markdown zip export (web app only), API |

*Pricing verified July 2026 — check [recall.it/pricing](https://www.recall.it/pricing) for current numbers; Recall raised Plus pricing at its 2.0 relaunch in April 2026.*

## Pricing: $120+/yr subscription vs a free app + your own AI key

Recall's free tier stores unlimited content but allows only **10 AI summaries a month** — the product's core is effectively paid. Plus is **$120/yr billed yearly**, and choosing which AI model answers you costs **$456/yr** on Max.

ForeverLM has no tiers to climb, because it has no tiers: the app is **free**, and every model in the in-app Chat is open. That Chat runs on your own OpenRouter key, and OpenRouter bills you at its cost with nothing added by ForeverLM; its free models cost nothing. Or connect whichever of Claude, ChatGPT, Gemini, or Grok you already subscribe to over MCP: your subscription covers the inference, and MCP itself is free. The in-app ledger accounts for it to the cent. There's no tier where the model picker lives, because the model picker was never behind one.

## Where Recall is better

- **Works everywhere.** Web app, iOS, and Android — save and review from any device. ForeverLM is Mac-only.
- **AI that stays free with no key.** Recall's free tier keeps giving you 10 AI summaries a month indefinitely at $0 with nothing to set up. ForeverLM's app is free, and its built-in AI needs your own OpenRouter key; free models on it cost nothing.
- **Knowledge graph and auto-tagging.** Recall automatically links related saves into a browsable graph; ForeverLM organizes by notebooks, source type, and Schedule instead.
- **Augmented browsing.** Recall's extension surfaces your saved knowledge while you browse the web.
- **Reddit imports.** Recall ingests Reddit threads; ForeverLM doesn't.

## Where ForeverLM is better

- **Deeper review.** Recall's spaced-repetition quizzes are generated Q&A cards. ForeverLM runs an explain-it-back conversation: you explain the source in your own words and an AI tutor with the full text probes for gaps and follows up. And review isn't paywalled behind a higher tier — see [Why Quizzing?](/why-quizzing)
- **Sources arrive by themselves.** Recall ingestion is save-by-save via the extension. ForeverLM auto-discovers from your Safari reading list, Apple Podcasts follows, and reference managers — your library reflects what you actually consume.
- **Podcasts as first-class sources.** Follow shows, get full episode transcripts, read or listen, and get quizzed on them — not just saved links.
- **Your cloud, not theirs.** Both apps are local-first, but Recall syncs through Recall's servers on Google Cloud; ForeverLM syncs through your own iCloud account, and the app's servers never store your library.
- **A study planner.** The weekly Schedule assigns sources to days with completion tracking and review history; Recall has a review queue but no planning surface.
- **No tiers and no caps.** No monthly summary allowance to ration, no model-choice upsell, no subscription needed (the app is free, MCP included); OpenRouter bills what you actually used, and nothing when you don't.

## Which should you choose?

Choose **Recall** if you need Android, Windows, or the web — or you want a free place to pile up saves with light AI summaries and are happy with card-style quizzing at $120/yr.

Choose **ForeverLM** if you're on a Mac and want the deeper loop: automatic source capture including full podcast transcripts, a weekly plan, review with the AI of your choice, and a library that lives in your own iCloud — free, MCP included, plus only what your AI use actually costs.
