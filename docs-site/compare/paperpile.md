---
layout: doc
title: ForeverLM vs Paperpile
description: Compare ForeverLM and Paperpile for paper management, PDFs, citations, AI assistants, full-library chat, pricing, and learning workflows.
---

# ForeverLM vs Paperpile

Paperpile is a polished, cloud-based reference manager for collecting papers, managing PDFs, and citing them in Google Docs, Microsoft Word, and LaTeX workflows. ForeverLM also collects and organizes papers, but folds them into a broader system for source-grounded chat, listening, planning, and active review.

Paperpile helps you move from **paper to citation**. ForeverLM helps you move from **paper to understanding**.

## At a glance

| | ForeverLM | Paperpile |
|---|---|---|
| **Price** | Free; AI on your own OpenRouter key at cost | Regular $99.60/year; Expert $138/year; eligible academics pay 50% less after a 30-day trial |
| **Platforms** | Mac-centered library with synced iPhone access | Web, iOS, and Android; browser extensions for Chrome, Safari, and Firefox |
| **Paper capture** | Browser reading lists, URL paste, local PDFs, MCP, and custom plugins; automatic open-PDF retrieval | One-click browser import, database and publisher integrations, identifier search, automatic PDF retrieval |
| **Organization** | Notebooks, source types, search, tags, status, and Schedule | Folders, labels, stars, filters, duplicate merging, full-text search, and shared libraries |
| **PDF workflow** | Reader, extracted text and figures, Text to Speech, Chat, and review | PDF reader; notes, highlighting, and collaboration on Expert |
| **Citations** | Stores paper metadata, but no cite-while-you-write plugin | Word and Google Docs plugins, BibTeX/LaTeX, 10,000+ styles, and Overleaf integration |
| **AI workflow** | Chat inside ForeverLM or connect any MCP assistant to search and operate the full library; sessions and reviews can be saved back | Ask AI beta uploads selected PDFs and prompts into ChatGPT, Claude, Gemini, Copilot, or Gemini Notebook |
| **Beyond papers** | Articles, books, podcasts, videos, courses, meetings, and X posts share the same notebooks and Chat | Focused on references, PDFs, and academic writing |
| **Storage** | Local SQLite + files in your private iCloud container | Account-based service with unlimited research PDF storage and optional Google Drive/OneDrive sync |

*Paperpile pricing and features checked against its [official pricing page](https://paperpile.com/pricing/) and [Ask AI documentation](https://paperpile.com/h/ask-ai/) in August 2026. All individual plans are billed annually.*

## AI is where the workflows diverge

Paperpile's Ask AI feature is a useful bridge. Select one or more PDFs, choose a research prompt, and Paperpile opens ChatGPT, Claude, Gemini, Copilot, or Gemini Notebook with the files attached. It is a pragmatic way to bring a paper into the assistant you already use.

ForeverLM supports that lightweight workflow too: drag selected sources into an AI chat. But it also goes further in two directions.

First, Chat is built into the source library. You can discuss the current paper or several sources, search the web, inspect paper figures, and keep the conversation alongside the notebook. Second, the MCP connection is persistent and two-way: an assistant can search the full library, retrieve content, organize notebooks, manage the Schedule, and save a completed review transcript back to ForeverLM. Paperpile says its MCP server is still in development, and its current Ask AI responses cannot automatically be saved back as library notes.

## Where Paperpile is better

- **Cite while you write.** Paperpile is designed for inserting citations and formatting bibliographies in Google Docs and Word, with strong BibTeX and Overleaf support. ForeverLM is not a manuscript citation tool.
- **Academic discovery and capture.** Its browser extension, database integrations, metadata repair, proxy support, and automatic PDF retrieval cover the messy long tail of scholarly publishing.
- **PDF annotation and collaboration.** Expert adds notes, highlights, shared folders and libraries, permissions, and collaborative PDF annotations.
- **Cross-platform access.** The web app and iOS/Android clients work well for researchers who are not Mac-only.
- **Unlimited hosted PDFs.** Every paid individual plan includes unlimited research PDF storage.
- **Google-centered workflows.** If your lab lives in Google Drive and Google Docs, Paperpile fits naturally.

## Where ForeverLM is more complete

- **Everything belongs to the same research context.** A paper can sit in a notebook with a podcast interview, an article, a conference video, meeting notes, and a book chapter—and Chat can reason across them together.
- **AI is not an export step.** Source-grounded conversation lives in the app, while MCP gives external assistants structured access to the full library instead of attaching a few PDFs to one thread.
- **The result comes back.** Review sessions retain their transcript, summary, score, and source links. The library records what was covered rather than forgetting the interaction when the external tab closes.
- **Papers can be heard as well as read.** Text to Speech cleans academic text for narration, skips citation clutter and reference sections, caches the audio, and syncs it to iPhone.
- **The reading queue is actionable.** Schedule papers for specific days, move them when plans change, and connect completion to a real review.
- **No reference-manager subscription.** The paper library, notebooks, Schedule, local reading, Text to Speech, built-in AI and MCP all come with the app, which is free. AI and voices run on your own OpenRouter key at OpenRouter's cost.

## Which should you choose?

Choose **Paperpile** if your center of gravity is academic writing: browser capture, clean metadata, PDF annotation, team libraries, and citations flowing into Google Docs, Word, BibTeX, or Overleaf. It is particularly compelling for Google-centric labs.

Choose **ForeverLM** if you want papers integrated with everything else you learn and you care more about asking, comparing, listening, scheduling, and remembering than cite-while-you-write.

They can also be complementary. Keep the full canonical bibliography in Paperpile, then bring the papers that matter to ForeverLM for cross-source research and review. If you want a free, open-source citation manager instead, see [ForeverLM vs Zotero](/compare/zotero).

## Why ForeverLM does not sync with Paperpile

There is no Paperpile plugin in ForeverLM, and none is planned. Everything ForeverLM does with a paper, from search and Chat to Text to Speech and review, works on a PDF that lives in your own iCloud library. A plugin that only pointed at your Paperpile records would enable none of it. So the route is a one-time move: export BibTeX from Paperpile into the `Paperpile` folder Paperpile syncs to Google Drive, and choose that folder in setup's Papers step (**Coming from a reference manager?**), or ask an assistant with the ForeverLM plugin to migrate it. Each paper goes through the normal pipeline, and papers without a synced PDF are added by DOI. Paperpile is never changed, and the papers are yours in ForeverLM from then on. See [Papers → Coming from a Reference Manager](/papers#coming-from-a-reference-manager).
