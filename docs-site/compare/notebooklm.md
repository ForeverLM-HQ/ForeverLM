---
layout: doc
title: ForeverLM vs NotebookLM (Gemini Notebook)
description: How ForeverLM compares to Google NotebookLM, now Gemini Notebook, on data ownership, model choice, retention, pricing, and podcast support.
---

# ForeverLM vs NotebookLM (Gemini Notebook)

NotebookLM, renamed **Gemini Notebook** in July 2026 and now at notebook.google.com, is Google's source-grounded AI assistant: upload documents into a notebook, chat with them, and generate impressive artifacts — most famously the podcast-style Audio Overviews. It's polished, generous at the free tier, and backed by Gemini. But it's built for *generating study material*, not for *learning over time* — and everything you put in lives on Google's servers, processed only by Google's models.

## At a glance

| | ForeverLM | Gemini Notebook |
|---|---|---|
| **Price** | 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost | Free tier (capped); higher limits via Google AI bundles: $7.99/mo Plus, $19.99/mo Pro, $99.99+/mo Ultra |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, for any model in Chat (free models cost nothing); or an AI subscription you already pay for, over MCP | Included, but capped per day/tier (chats, overviews, quizzes) |
| **Platforms** | Native macOS app (macOS 14+) | Web + iOS + Android apps; no desktop app |
| **Data storage** | Local SQLite + files in your private iCloud container | Google's servers — every source must be uploaded |
| **AI models** | Any MCP-compatible AI (Claude, ChatGPT, Gemini, Grok), or any model in-app through your own OpenRouter key | Gemini only, no model picker, no bring-your-own-key |
| **Source ingestion** | Automatic: Safari reading list, Apple Podcasts, PDFs, papers, books, YouTube, X posts | Manual upload per notebook (plus Drive links and Deep Research discovery) |
| **Podcasts** | Follow shows, full episode transcripts as sources | Not supported (it *generates* podcast-style audio; it can't ingest your podcast feed) |
| **Knowledge accumulation** | Notebooks drawing on one persistent library — a source is added once and can be in any number of notebooks | Isolated notebooks with per-notebook source caps (50–600 by tier) |
| **Retention** | Cards you keep from your sources, brought back on a spaced schedule across every notebook, plus review sessions with saved history | One-shot flashcards/quizzes — no spaced repetition, no tracking over time |
| **Export** | Files stay on your Mac; SQLite you can open | Notes to Google Docs/Sheets, audio as WAV; notebook structure and chats effectively locked in |

*Prices verified July 2026, limits October 2026. Google reshuffles these often: since September 2026 a personal account's usage refills every five hours up to a weekly cap instead of fixed daily counts. Check [Google's limits page](https://support.google.com/gemininotebook/answer/16213268) for current numbers.*

## Pricing: free-but-capped bundles vs your own AI key

Gemini Notebook itself is free, with up to 100 notebooks of 50 sources each and usage that refills every five hours up to a weekly cap; Google no longer publishes the numbers for personal accounts. Raising the limits means a Google AI plan — **$199.99/yr for AI Pro**, with 300 sources per notebook and four times the standard usage — that bundles much more than Gemini Notebook, and the limits still exist, just higher. You're paying a flat annual fee for permission to do more, not for what you did.

ForeverLM is **7 days free, then $19 once** (no subscription), and has no daily caps of its own. There are no tiers to upgrade through: bring your own OpenRouter key, pick any model in the in-app Chat, and OpenRouter bills you at its cost with nothing added by ForeverLM, or use free models and pay nothing. Or connect the Claude, ChatGPT, Gemini, or Grok subscription you already pay for over MCP: that subscription covers the inference, and ForeverLM charges nothing per request. In the app, a little also goes to background work like transcript cleanup, billed the same way; search embeddings are made on your Mac, for free. Every conversation's cost is shown to the cent.

## Where Gemini Notebook is better

- **Audio and Video Overviews.** The generated podcast-style discussions are best-in-class and genuinely delightful. A ForeverLM notebook's audio overview is one narrator reading a script written from its sources (a deep dive, a brief or a critique), and Text to Speech reads you the *actual source*; there is no two-host show, and ForeverLM's videos are short explainer films of one concept rather than a video overview of a notebook.
- **Genuinely free AI, forever, with no key.** A Google account is the only requirement, and within the daily caps the free tier costs nothing indefinitely. ForeverLM is paid after its 7 free days, and its built-in AI runs on your own OpenRouter key: free models cost nothing, paid ones cost what OpenRouter charges.
- **Cross-platform.** Web, iOS, and Android apps. ForeverLM is Mac-only today.
- **Google-scale polish** and Drive/Docs integration if you live in Workspace.

## Where ForeverLM is better

- **Your data never leaves your control.** ForeverLM's library is a local SQLite database plus files in your private iCloud container, synced through your Apple account. Gemini Notebook requires uploading everything to Google, with no local copy and a weak export story.
- **Any AI, not one AI.** ForeverLM works with Claude, ChatGPT, Gemini, Grok, or any model through your own OpenRouter key — use the subscription you already pay for, switch anytime. Gemini Notebook is Gemini-only with no model visibility at all.
- **A learning system, not a generator.** Gemini Notebook produces flashcards and quizzes as one-shot artifacts — nothing schedules review, nothing tracks what you've mastered. ForeverLM keeps the cards you choose, brings them back on a spaced schedule across every notebook, runs review sessions where you explain sources back and the AI probes your gaps, and keeps the full review history per source. See [Why Quizzing?](/why-quizzing)
- **One library for life, under every notebook.** Gemini Notebook silos knowledge into notebooks capped at 50–600 sources, each with its own uploads. A ForeverLM notebook draws on a single accumulating library — five years of reading, listening, and studying in one searchable place — so a paper is added once, can be in any number of notebooks, and a notebook's Add sources searches the whole library first.
- **Real podcast support.** Follow your shows, get full transcripts, read/listen/review. Gemini Notebook can't subscribe to a podcast feed at all.
- **Sources flow in automatically** from your Safari reading list, Apple Podcasts, and reference managers — no per-notebook uploading ritual.
- **Your notebooks come with you.** Paste a notebook's link into ForeverLM and it becomes a ForeverLM notebook: its sources, its chats and its notes, kept in your own library. See [Importing a Gemini Notebook](/studio#importing-a-gemini-notebook).

## Which should you choose?

Choose **Gemini Notebook** for ad-hoc research sprints: dump twenty documents into a notebook, chat with them, generate an Audio Overview for the commute — especially if you're not on a Mac, or you'd rather have AI that stays free indefinitely inside its caps than AI you meter.

Choose **ForeverLM** if learning is ongoing, not one-off: you want everything you read, watch, and hear accumulating in a library *you* own, reviewed on a schedule, with proof you actually understood it — using whichever AI you already trust.
