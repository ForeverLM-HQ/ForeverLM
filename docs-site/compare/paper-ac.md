---
layout: doc
title: ForeverLM vs Paper (paper.ac)
description: How ForeverLM compares to Paper (paper.ac), the study workspace that is free in beta, on pricing, AI models, where your library lives, flashcards, podcasts, and review.
---

# ForeverLM vs Paper (paper.ac)

Paper (paper.ac) is a study workspace that sets out to replace NotebookLM, Notion, Anki and Quizlet at once. You upload PDFs, lectures, videos and web pages, chat with them, and turn them into notes, FSRS flashcards, quizzes, podcasts and slide decks, all inside a Notion-style editor. It is free while in beta. ForeverLM overlaps on the study loop. It differs on where the library lives (your iCloud, not a vendor's cloud), which AI runs it (any model, or the assistant you already use), and how sources arrive (on their own, podcasts included).

## At a glance

| | ForeverLM | Paper |
|---|---|---|
| **Price** | Free; MCP is 30 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost, or over MCP from an assistant you already pay for | Free during the beta ("free unlimited credits"); paid plans for heavier use are announced but not priced |
| **Platforms** | Native macOS app (macOS 14+), with an iPhone app and a web library | Web app (works in mobile browsers); a Mac desktop app in testing; a native mobile app planned |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Paper's cloud (Supabase on AWS, region not stated), encrypted in transit and at rest, not end-to-end |
| **AI models** | Any model through your own OpenRouter key, or Claude, ChatGPT, Gemini or Grok over MCP | Grok by default, GPT and Gemini per chat (its roadmap lists Claude as added); no bring-your-own-key yet |
| **Assistant access** | A full MCP server: search, add sources, run reviews, write Pages | No MCP; a public API is on the roadmap |
| **Sources** | Papers with their PDFs, articles, books, podcasts (follow shows, full transcripts), YouTube, X posts, meetings; reading lists and Apple Podcasts arrive on their own | What you upload or link: PDF (with OCR), audio, video, EPUB, Word, PowerPoint, Markdown, web pages, YouTube, Notion and Outline imports |
| **Flashcards** | Cards drafted from what you finish, kept or skipped by you, reviewed on a schedule | FSRS flashcards (basic and cloze), up to 75 per generation |
| **Review** | Explain a source back to a tutor that reads its whole text; saved per source | Quizzes and self-graded review sessions of 8–15 questions |
| **Audio** | A one-narrator audio overview (deep dive, brief or critique); Text to Speech reads the source itself | Generated podcasts, solo or two hosts, up to 60 minutes |
| **Export** | Files on your Mac; SQLite you can open | Notes as Markdown; a full-account export by email request |

*Checked against paper.ac's own pages (FAQ, How it works, Security, Docs, Roadmap and Changelog) in October 2026. Paper is in beta and changes quickly, so check [paper.ac](https://paper.ac) for its current state.*

## Pricing: a free beta vs a free app and your own key

Paper costs nothing while it is in beta, with no key to bring. Its terms already describe monthly billing for paid features, and its own pages say paid tiers may come later for heavy use, large libraries and teams. No prices are published yet, so Paper's cost today is $0 and its long-term cost is unknown.

ForeverLM is free, with no subscription and no tiers; only MCP, the connection for an outside assistant, is paid: 30 days free, then $19 once. The models run on your own OpenRouter key, which OpenRouter bills at its own price with nothing added by ForeverLM. You can also connect the Claude, ChatGPT, Gemini or Grok subscription you already pay for over MCP. The app shows what every conversation cost, to the cent.

## Where Paper is better

- **It is free today.** No key and nothing to pay during the beta.
- **It runs anywhere there is a browser.** Windows, Linux, Chromebooks and phones all work. ForeverLM is Mac-centered.
- **Two-host podcasts and slide decks.** Paper's podcasts can have one or two hosts and run up to an hour, and it makes slide decks from any source. ForeverLM's audio overview has one narrator, and it makes no slides.
- **FSRS with four ratings.** Paper schedules cards with FSRS and rates them Again, Hard, Good or Easy, with cloze cards for definitions. ForeverLM's cards have two buttons, Forgot and Remembered.
- **A writing and team workspace.** A Notion-style block editor, boards with timelines, and channels and direct messages for working with others.

## Where ForeverLM is better

- **Your library stays in your iCloud.** Paper keeps everything on its own cloud, without end-to-end encryption or a SOC 2 report, and a full export means emailing them. ForeverLM's library is a SQLite database and files in your private iCloud container, and its servers never hold it.
- **Any model, and the assistant you already use.** Paper chooses among Grok, GPT and Gemini, with no key of your own. ForeverLM runs any model on your OpenRouter key, and Claude, ChatGPT, Gemini or Grok can work in your library over MCP.
- **Sources arrive on their own.** Safari, Chrome and Brave reading lists, Apple Podcasts episodes with full transcripts, X bookmarks, YouTube likes and meeting transcripts. Paper holds what you upload or paste.
- **Review that checks understanding.** You explain a source back to a tutor that has read all of it and probes the gaps, and the result stays with the source. Cards are drafted for you as you finish things. See [Why Quizzing?](/why-quizzing)
- **A price you can read today.** ForeverLM states what it costs now. Paper's paid tiers are announced but not priced.
- **Gemini Notebook moves in whole.** Paste a notebook's link and its sources, chats and notes arrive as a ForeverLM notebook ([Importing a Gemini Notebook](/studio#importing-a-gemini-notebook)).

## Which should you choose?

Choose **Paper** if you want a free, browser-based study workspace with podcasts, slides and FSRS flashcards today, and you don't mind your library living on its cloud.

Choose **ForeverLM** if you're on a Mac and want one private library you keep for years: sources that arrive on their own, any model you like, and review that checks you understood what you read, watched or heard.
