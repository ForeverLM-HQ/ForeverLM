---
layout: doc
title: ForeverLM vs Anki
description: How ForeverLM compares to Anki — AI-driven review of your real sources versus self-graded spaced-repetition flashcards.
---

# ForeverLM vs Anki

Anki is the standard-bearer of spaced repetition: free, open source, fifteen-plus years old, and beloved by med students and language learners. If your goal is memorizing thousands of discrete facts, Anki is hard to beat. ForeverLM aims at a different target: understanding and retaining the *sources* you consume — articles, papers, podcasts, books — by explaining them back to an AI tutor rather than flipping self-graded cards.

## At a glance

| | ForeverLM | Anki |
|---|---|---|
| **Price** | Free; MCP is 30 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost | Free on desktop and Android; AnkiMobile for iOS is $24.99 one-time |
| **AI costs** | Your own OpenRouter key, billed by OpenRouter at cost with nothing added, for any model in Chat (free models cost nothing); or an AI subscription you already pay for, over MCP | No built-in AI; desktop-only community add-ons, bring-your-own-key |
| **Platforms** | Native macOS app (macOS 14+) | Windows, macOS, Linux, iOS, Android, web review |
| **Data storage** | Local SQLite + files in your private iCloud container | Local SQLite; free AnkiWeb sync or self-hosted sync |
| **Source ingestion** | Automatic: articles, papers, podcasts, books, YouTube, X posts | None — cards only; you author or import decks |
| **Review method** | Review dialogue: explain it back, AI probes gaps | Self-graded flashcards (Again/Hard/Good/Easy), SM-2 or FSRS |
| **Adaptivity** | AI rephrases, follows up on weak spots, asks *why* | Cards are static; scheduling adapts, questions don't |
| **Export** | Files on your Mac; SQLite you can open | Excellent: .apkg/.colpkg/plain text, open format |

*Pricing verified July 2026 — see [apps.ankiweb.net](https://apps.ankiweb.net/).*

## Pricing: neither one has to be a subscription

This is one comparison where the funding models nearly agree: neither app has to bill you every month. Anki is free (or $24.99 once on iOS). ForeverLM is free too; only MCP, the connection for an outside assistant, costs anything: 30 days free, then $19 once, with no subscription. AI is a separate bill you control: bring your own OpenRouter key and pay models at cost, or use free models and pay nothing.

There are two ways to use AI, and you can mix them. Use the in-app Chat with any model you like on your own OpenRouter key, and OpenRouter bills you at its cost with nothing added by ForeverLM. Or connect the Claude, ChatGPT, Gemini, or Grok subscription you already pay for over MCP: your subscription covers the thinking, and ForeverLM charges nothing per request. Anki, of course, charges nothing to run at all, because it has no AI to bill you for.

## Where Anki is better

- **Cost and platform reach.** Free almost everywhere — Windows, Linux, and Android included — and it will never send you an AI bill, because there's no AI in it.
- **Rote memorization at scale.** For vocabulary, anatomy, drug names, dates — thousands of discrete facts — self-graded flashcards with FSRS scheduling are the proven tool.
- **Shared decks.** Decades of community decks (med school, languages) you can download and start reviewing today.
- **Total ownership.** Open source, local files, self-hostable sync. The strongest possible longevity story.
- **Zero AI dependency.** Works offline forever, no API keys, no cloud anything.

## Where ForeverLM is better

- **Understanding, not recognition.** Anki asks "do you remember this card?" and you grade yourself. ForeverLM asks you to *explain the concept from scratch* while an AI tutor with the full source text checks your explanation, probes gaps, and asks follow-ups. Static cards can't probe a gap they don't know about — see [Why Quizzing?](/why-quizzing)
- **No card authoring.** Anki's hidden cost is the hours spent making good cards. ForeverLM skips the authoring step entirely: the source itself is the study material, and questions are generated fresh from it every session.
- **Sources flow in automatically.** Safari reading list, Apple Podcasts follows, PDFs, papers, books, YouTube — ForeverLM tracks what you actually consume. Anki has no concept of a source.
- **A study planner, not just a review queue.** The weekly Schedule assigns sources to days and tracks completion and review history — closer to a study system than a card queue.
- **Modern native Mac experience.** Reader, Text to Speech, in-app Chat — versus Anki's famously dated UI.

## Which should you choose?

Choose **Anki** for high-volume rote memorization — exams with thousands of facts, language vocabulary — especially on Windows, Linux, or Android, or if you want a zero-cost, zero-cloud tool that will outlive every startup.

Choose **ForeverLM** if your problem is the flood of articles, papers, podcasts, and books you consume and forget — and you want to be tested on real understanding without spending evenings authoring flashcards.

They're complementary: several ForeverLM users keep Anki for pure memorization and use ForeverLM as the comprehension loop over their reading.
