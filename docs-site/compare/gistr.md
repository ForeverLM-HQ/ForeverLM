---
layout: doc
title: ForeverLM vs Gistr
description: How ForeverLM compares to Gistr, the AI notebook for YouTube, podcasts, PDFs and articles, on credit pricing, AI models, retention, platforms, and where your library lives.
---

# ForeverLM vs Gistr

Gistr calls itself an AI-native notebook. You save YouTube videos, podcasts, PDFs and articles, ask questions about them in threads, and write notes that link back to the exact timestamp or page, grouped into collections. Plans are credit-based, with stronger models and deep research on the higher tiers. ForeverLM shares the "keep what you watch and hear" idea. It differs on where the library lives (your iCloud), which AI runs it (any model, at what it costs), and what happens after saving: a schedule, cards and review.

## At a glance

| | ForeverLM | Gistr |
|---|---|---|
| **Price** | Free; MCP is 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost, or over MCP from an assistant you already pay for | Free (500 credits/mo, 5 collections, 5 sources per thread); Curious $8/mo; Explorer $16/mo; Thinker $40/mo; yearly billing gives two months free |
| **Platforms** | Native macOS app (macOS 14+), with an iPhone app and a web library | Web, Chrome extension, Android; iOS in development; no desktop app |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Gistr's cloud; hosting provider and region not stated; says your content is never used for training |
| **AI models** | Any model through your own OpenRouter key, or Claude, ChatGPT, Gemini or Grok over MCP | By tier: fast models on Free, frontier Claude, GPT and Gemini from Explorer ($16/mo); no bring-your-own-key |
| **Assistant access** | A full MCP server: search, add sources, run reviews, write Pages | None documented |
| **Sources** | Papers with their PDFs, articles, books, podcasts (follow shows, full transcripts), YouTube, X posts, meetings; reading lists and Apple Podcasts arrive on their own | What you save or upload: YouTube (playlists from Explorer), podcasts from Apple Podcasts or Spotify links, web pages, PDF, Word, PowerPoint, EPUB, Markdown, audio, images |
| **Retention** | Weekly Schedule, cards drafted as you finish sources, and a review dialogue saved per source | One-click quizzes; no flashcards or spaced repetition documented |
| **Notes** | Pages in notebooks, linked to the passages they cite | Notes linked to timestamps and pages, in threads and collections |
| **Export** | Files on your Mac; SQLite you can open | Notes as PDF, image or Markdown; other data on request |

*Checked against gistr.so's pricing, FAQ, privacy policy and terms, and its Chrome Web Store and Google Play listings, in October 2026. Check [gistr.so/pricing](https://gistr.so/pricing) for current numbers.*

## Pricing: credit tiers vs your own key

Gistr meters AI in credits: 500 a month free, 2,500 on Curious ($8), 10,000 on Explorer ($16) and 55,000 on Thinker ($40), with unused credits rolling over up to a cap on paid plans. The tier also decides the model: the most capable Claude, GPT and Gemini models start at Explorer. On the free plan, content you haven't touched for three months goes cold and has to be processed again before you can ask about it.

ForeverLM is free, with no subscription and no tiers: the whole app and every model are open. Only MCP, the connection for an outside assistant, is paid: 7 days free, then $19 once. The models run on your own OpenRouter key, which OpenRouter bills at its own price with nothing added by ForeverLM, and the app shows what every conversation cost, to the cent. You can also connect the Claude, ChatGPT, Gemini or Grok subscription you already pay for over MCP, which is what the $19 covers.

## Where Gistr is better

- **Video and podcast notes.** Notes that jump to the exact moment in a video or episode are Gistr's centre, and it takes Spotify podcast links. ForeverLM reads podcast transcripts from Apple Podcasts only.
- **Cheap to start, and on Android.** A free plan, an $8 tier, and apps for the web and Android. ForeverLM is Mac-centered.
- **Deep research built into the tiers.** Explorer and Thinker run deep research across the web from inside a thread.

## Where ForeverLM is better

- **Saving is not the end.** ForeverLM schedules what you saved, drafts cards as you finish sources, and runs a review dialogue in which a tutor who has read the whole source checks that you understood it. Gistr documents quizzes, but no flashcards or spaced repetition. See [Why Quizzing?](/why-quizzing)
- **Every model, no tiers.** No tier decides which model you may use, and nothing goes cold.
- **Your library stays in your iCloud.** ForeverLM's library is a SQLite database and files in your private iCloud container, and its servers never hold it. Gistr's library lives on its cloud.
- **Sources arrive on their own.** Reading lists, Apple Podcasts episodes with full transcripts, X bookmarks, YouTube likes and meeting transcripts, without a save button.
- **The assistant you already use.** Claude, ChatGPT, Gemini or Grok can search your library, add to it and run your reviews over MCP.
- **Gemini Notebook moves in whole.** Paste a notebook's link and its sources, chats and notes arrive as a ForeverLM notebook ([Importing a Gemini Notebook](/studio#importing-a-gemini-notebook)).

## Which should you choose?

Choose **Gistr** if you mostly learn from YouTube and podcasts, want notes pinned to timestamps, and use Android or the web.

Choose **ForeverLM** if you're on a Mac and want what you watch, read and hear to land in one private library on its own, and then to stick, through a schedule, cards and review.
