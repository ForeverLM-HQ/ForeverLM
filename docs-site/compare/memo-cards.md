---
layout: doc
title: ForeverLM vs Memo (memo.cards)
description: How ForeverLM compares to Memo (memo.cards, formerly PDF2Anki) on pricing, flashcards and FSRS, Anki export, AI models, platforms, and where your library lives.
---

# ForeverLM vs Memo (memo.cards)

Memo (memo.cards, formerly PDF2Anki) was built by medical students to turn study material into flashcards. It has grown into an AI study workspace: upload lectures, PDFs, slides and videos, then get FSRS flashcards, practice tests, notes, mind maps, podcasts and guided voice walkthroughs, with export straight to Anki. It runs on almost every platform. ForeverLM is aimed at a different job: one private library of everything you read, watch and listen to, kept in your own iCloud, with review that checks you understood it.

## At a glance

| | ForeverLM | Memo |
|---|---|---|
| **Price** | 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost, or over MCP from an assistant you already pay for | Free plan (limits not published); Pro $20/mo or $120/yr; Max $50/mo or $300/yr. Usage draws on a monthly "energy" balance with no fixed number of generations |
| **Platforms** | Native macOS app (macOS 14+), with an iPhone app and a web library | Web, Mac, Windows, Linux, iOS; Android as a web app; Chrome extension |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Memo's cloud; hosting provider and region not stated; a copy of your data on request |
| **AI models** | Any model through your own OpenRouter key, or Claude, ChatGPT, Gemini or Grok over MCP | Standard, Thinking and Pro modes; the models are not named; no bring-your-own-key |
| **Assistant access** | A full MCP server: search, add sources, draft cards, run reviews | None documented |
| **Sources** | Papers with their PDFs, articles, books, podcasts (follow shows, full transcripts), YouTube, X posts, meetings; reading lists and Apple Podcasts arrive on their own | What you upload or link: PDF, Word, PowerPoint, spreadsheets, EPUB, audio, video, images, YouTube, web pages; lecture recordings through its extension |
| **Flashcards** | Cards drafted from what you finish, kept or skipped by you, reviewed with Forgot and Remembered | FSRS scheduling; basic, quiz, cloze and image-occlusion cards; Anki (.apkg) and RemNote export |
| **Review** | Explain a source back to a tutor that reads its whole text; saved per source | Practice tests and AI tutors, including a voice tutor |
| **Audio** | A one-narrator audio overview (deep dive, brief or critique); Text to Speech reads the source itself | Podcasts of about 3 to 15 minutes; guided voice walkthroughs (Track Mode) |
| **Export** | Files in your iCloud Drive; SQLite you can open | Cards to Anki and RemNote; notes as PDF, Markdown or text |

*Checked against memo.cards's pricing, FAQ, help center and download pages and its App Store listing in October 2026. Prices are the web prices; the iOS app lists different in-app prices, so check [memo.cards](https://www.memo.cards/en/pricing) for the offer where you buy.*

## Pricing: an energy meter vs your own key

Memo's free plan needs no card, and its paid plans are Pro at $20 a month ($120 billed yearly) and Max at $50 a month ($300 billed yearly). What a plan buys is a monthly balance of "energy", and Memo says a plan does not promise a fixed number of generations. You find out how far it goes by using it.

ForeverLM is 7 days free, then $19 once, with no subscription and no tiers. The models run on your own OpenRouter key, which OpenRouter bills at its own price with nothing added by ForeverLM, and the app shows what every conversation cost, to the cent. You can also connect the Claude, ChatGPT, Gemini or Grok subscription you already pay for over MCP.

## Where Memo is better

- **Flashcards are its core.** FSRS scheduling, cloze and image-occlusion cards, and export to Anki with image occlusion intact. For exam memorization, such as medical school, it is the stronger card tool.
- **Every platform.** Web, Mac, Windows, Linux and iOS, with Android as a web app. ForeverLM is Mac-centered.
- **More output styles.** Mind maps, infographics, several note formats (Cornell among them), podcasts and guided voice walkthroughs.
- **A free plan with no key.** You can start without an API key or a card.

## Where ForeverLM is better

- **Your library stays in your iCloud.** Memo keeps your material on its own cloud and names neither its hosting provider nor most of its AI providers. ForeverLM's library is a SQLite database and files in your private iCloud container, and its servers never hold it.
- **Any model, and the assistant you already use.** Memo's modes don't say which model answers. ForeverLM runs any model you choose on your own key, and Claude, ChatGPT, Gemini or Grok can work in your library over MCP.
- **Costs you can read.** An energy balance makes cost a guess. ForeverLM records every call's price.
- **Sources arrive on their own.** Reading lists, Apple Podcasts episodes with full transcripts, PDFs dropped into iCloud folders, X bookmarks, YouTube likes and meeting transcripts. Memo holds what you upload.
- **A library, not decks.** Every source lives once in your library and can sit in any number of notebooks, with a Schedule and a review dialogue tied to the source. The tutor reads the whole source and probes the gaps a card can't know about. See [Why Quizzing?](/why-quizzing)
- **Gemini Notebook moves in whole.** Paste a notebook's link and its sources, chats and notes arrive as a ForeverLM notebook ([Importing a Gemini Notebook](/studio#importing-a-gemini-notebook)).

## Which should you choose?

Choose **Memo** if you're memorizing for exams, you want FSRS cards with cloze and image occlusion that export to Anki, or you need Windows, Linux or Android.

Choose **ForeverLM** if you're on a Mac and want a private, lasting library of everything you consume, with any model you like and review that checks understanding rather than recall alone.

They can sit side by side: make exam decks in Memo, and keep the papers, lectures and podcasts behind them in ForeverLM.
