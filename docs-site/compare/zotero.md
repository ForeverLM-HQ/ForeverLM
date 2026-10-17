---
layout: doc
title: ForeverLM vs Zotero
description: Compare ForeverLM and Zotero for managing academic papers — PDFs, metadata, citations, storage, AI chat, listening, and active review.
---

# ForeverLM vs Zotero

Zotero is the open-source standard for collecting references, managing citation metadata, annotating PDFs, and generating bibliographies. ForeverLM overlaps on building and organizing a paper library, but it is aimed at a different outcome: reading, listening to, discussing, and remembering the research alongside all your other learning sources.

This is not a claim that ForeverLM replaces Zotero for academic writing. It does not. If your next step is inserting a perfectly formatted citation into a manuscript, Zotero is the better tool. If your next step is understanding how the paper changes your thinking, ForeverLM carries the workflow further.

## At a glance

| | ForeverLM | Zotero |
|---|---|---|
| **Price** | Free; MCP is 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost | Free and open source; 300 MB file sync free, then $20/year for 2 GB, $60/year for 6 GB, or $120/year unlimited |
| **Platforms** | Mac-centered library with synced iPhone access | Mac, Windows, Linux, iOS, Android, and web library |
| **Paper capture** | Browser reading lists, URL paste, local PDFs, MCP, and custom plugins; open PDFs fetched when available | Excellent browser plugin, DOI/ISBN lookup, database translators, file import, and feeds |
| **Organization** | Notebooks, source types, search, status, tags, and a day-by-day Schedule | Collections, tags, related items, saved searches, duplicate detection, and group libraries |
| **PDF reading** | Built-in reader, extracted text, figures, Text to Speech, and source-grounded Chat | Mature PDF reader with highlights, notes, image annotations, and annotation-to-note workflows |
| **Citations** | Stores paper metadata, but no manuscript citation or bibliography plugin | Best-in-class Word, LibreOffice, and Google Docs citation workflow with thousands of CSL styles |
| **AI** | In-app multi-source Chat, model choice, web search, MCP library tools, and saved source-linked review transcripts | Community plugins can add AI workflows; AI is not the core Zotero learning loop |
| **Learning** | Schedule, source chat, review, scores, and linked review history | No built-in study schedule or active-recall workflow |
| **Storage** | Local SQLite + files in your private iCloud container | Local-first; optional Zotero Storage or WebDAV for attachment sync |

*Zotero capabilities and storage pricing checked against its [official guide](https://www.zotero.org/support/quick_start_guide) and [storage page](https://www.zotero.org/support/individual_storage) in August 2026.*

## Where Zotero is better

- **Citations and bibliographies.** Zotero inserts and updates citations in Word, LibreOffice, and Google Docs, switches styles across an entire manuscript, and generates the bibliography automatically. ForeverLM does not do this.
- **PDF annotation.** Highlights, notes, image annotations, and annotation-backed notes are a mature part of Zotero's research workflow.
- **Reference capture.** Zotero's translators recognize an enormous range of publisher pages, library catalogs, databases, and item types.
- **Collaboration.** Group libraries and shared annotations make Zotero a much better fit for labs, classes, and coauthors.
- **Open ecosystem.** Zotero is free, open source, extensible through plugins, and available across desktop platforms.
- **Bibliographic rigor.** Complex metadata, citation styles, attachment relationships, and reference exports are its home territory.

## Where ForeverLM is more complete

- **The paper is part of a wider knowledge library.** Research sits beside articles, books, podcasts, videos, courses, and meetings instead of living in a paper-only workflow.
- **You can chat with the library directly.** Ask questions about one paper, compare several, search across everything, or let an MCP-connected assistant organize sources and notebooks. The conversation can happen inside ForeverLM and stay linked to the material.
- **Reading and listening are built in.** ForeverLM extracts the full text, exposes paper figures in Chat, and can turn a paper into cached audio while removing bibliography and citation noise from narration.
- **Planning is first-class.** Put papers on specific days, move unfinished work, and see whether a source is pending, reviewed, or complete.
- **Review tests understanding.** Instead of stopping at highlights and notes, explain the paper back to an AI tutor that can probe the methodology, evidence, limitations, and conceptual gaps.
- **Full-text retrieval is part of ingestion.** ForeverLM attempts direct open-access downloads, PubMed Central copies, and configured institutional access, while recording paywall status when a PDF cannot be obtained.

## Which should you choose?

Choose **Zotero** if you are writing papers, dissertations, or reports and need precise citations, bibliographies, annotation, collaboration, or a cross-platform open-source reference manager. It is exceptional at that job and costs nothing unless you want more hosted file storage.

Choose **ForeverLM** if paper management is the beginning rather than the end: you want research mixed with the rest of your source library, scheduled into your week, available to AI conversation, listenable on the go, and followed by active review.

For many researchers, the honest answer is **both**. Keep Zotero as the citation system of record. Use ForeverLM for the smaller set of papers you intend to understand deeply and connect to articles, talks, books, and ongoing notebooks.

## Why ForeverLM does not sync with Zotero

There is no Zotero plugin in ForeverLM, and none is planned. Everything ForeverLM does with a paper, from search and Chat to Text to Speech and review, works on a PDF that lives in your own iCloud library. A plugin that only pointed at your Zotero records would enable none of it. So the route is a one-time move: choose your Zotero data folder in setup's Papers step (**Coming from a reference manager?**), or ask an assistant with the ForeverLM plugin to migrate the library. Either way the Zotero data folder, or a BibTeX or RIS export with its files, is read and each paper goes through the normal pipeline. Zotero is read, never changed, and the papers are yours in ForeverLM from then on. See [Papers → Coming from a Reference Manager](/papers#coming-from-a-reference-manager).
