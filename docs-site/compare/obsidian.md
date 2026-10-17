---
layout: doc
title: ForeverLM vs Obsidian
description: How ForeverLM compares to Obsidian — a source-tracking learning loop versus a build-it-yourself local-first note-taking system.
---

# ForeverLM vs Obsidian

Obsidian is the gold standard for owning your notes: free, local Markdown files, endlessly extensible through community plugins. ForeverLM shares Obsidian's core value — your data lives on your machine, not in someone's cloud — but it solves a different problem. Obsidian is a place to *write and link notes*. ForeverLM is a system to *track what you consume and verify you understood it*. See [Why not a note-taking app?](/why-quizzing#why-not-a-note-taking-app)

## At a glance

| | ForeverLM | Obsidian |
|---|---|---|
| **Price** | Free; MCP is 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost; iCloud sync included, no paid sync tier | Free (core app, including commercial use). Sync add-on $4–8/mo; Publish $8/mo |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, for any model in Chat (free models cost nothing); or an AI subscription you already pay for, over MCP | No built-in AI; community plugins, almost all bring-your-own-key |
| **Platforms** | Native macOS app (macOS 14+) | macOS, Windows, Linux, iOS, Android |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Local Markdown files; optional E2E-encrypted paid sync, or DIY iCloud/git sync |
| **Source ingestion** | Automatic: Safari reading list, Apple Podcasts, PDFs, papers, books, YouTube, X posts | None built in — web clipper for articles; everything else via plugins or manual |
| **Podcasts** | Follow shows, full episode transcripts | Not supported natively |
| **Review method** | Review dialogue with an AI tutor | None built in; community spaced-repetition plugins, self-graded |
| **Model choice** | Any MCP-compatible AI, or any model in-app through your own OpenRouter key | Whatever a plugin supports (BYOK, incl. local models via Ollama) |
| **Export** | Files on your Mac; SQLite you can open | Zero lock-in — it's already a folder of .md files |

*Pricing verified July 2026 — check [obsidian.md/pricing](https://obsidian.md/pricing) for current numbers.*

## Pricing: both respect your wallet

Obsidian's core app is genuinely free, and if you sync via iCloud or git, it stays free. Paid Sync is $48–96/yr. AI features require assembling plugins and paying per-token with your own keys.

ForeverLM is free, and iCloud sync is included: there's no paid sync tier to graduate onto. AI is a separate bill you control: the in-app Chat runs on your own OpenRouter key, billed by OpenRouter at its cost with nothing added, or on free models for nothing. Driving the app over MCP from a Claude, ChatGPT, Gemini, or Grok subscription you already have is the one paid part: 7 days free, then $19 once. Neither product puts a subscription between you and your own data. The difference is that Obsidian leaves the AI wiring to you, and ForeverLM wires your key in for you.

## Where Obsidian is better

- **It runs everywhere**, Windows, Linux, and Android included, and its core app costs nothing. ForeverLM is free too, but it is Mac-centered, and its built-in AI needs your own OpenRouter key.
- **Freeform thinking.** Backlinks, graph view, canvas, daily notes — if you want to write, link, and structure your own ideas, Obsidian is built for exactly that. ForeverLM deliberately isn't a note-taking app.
- **Ultimate data ownership.** Plain Markdown on disk beats every other storage model for longevity, including ForeverLM's SQLite-plus-iCloud.
- **The plugin ecosystem.** Thousands of community plugins; if you can imagine a workflow, someone has built it.
- **Local AI.** Plugins can run against Ollama models entirely offline — ForeverLM's AI review requires a cloud provider.

## Where ForeverLM is better

- **Capture is automatic.** Obsidian ingests nothing by itself — no articles, no podcasts, no papers, no highlights. ForeverLM auto-discovers sources from your Safari reading list, Apple Podcasts follows, and reference managers. Many Obsidian users pay $120/yr for Readwise just to pipe content in.
- **A learning loop exists out of the box.** Obsidian has no review system; spaced-repetition plugins are self-graded flashcards you configure and maintain yourself. ForeverLM ships a weekly Schedule, AI review sessions, and per-source understanding history — no assembly required.
- **The AI reads your actual sources.** Through MCP, Claude, ChatGPT, Gemini, or Grok can search your whole library, pull full source text, quiz you on it, and save the review back. Obsidian AI plugins mostly operate on your notes, not on original source material.
- **Sources, not just notes about sources.** ForeverLM tracks the article, the paper PDF, the episode transcript itself — with a built-in Reader and Text to Speech — so review is grounded in what the author wrote, not what you managed to write down.
- **Zero blank-canvas problem.** Obsidian's flexibility is also its tax: you design and maintain your own system. ForeverLM has one opinionated loop: track, schedule, read or listen, explain it back.

## Which should you choose?

Choose **Obsidian** if your center of gravity is writing and linking your own notes, you need Windows/Linux/Android, or you enjoy building a personal system from plugins.

Choose **ForeverLM** if you're on a Mac and your problem isn't note storage — it's that you read, watch, and listen to a flood of material and retain too little of it.

Many people run both: Obsidian for thinking and writing, ForeverLM for tracking sources and verifying understanding. Both keep your data local, so neither locks the other out.
