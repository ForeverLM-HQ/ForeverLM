---
layout: doc
title: ForeverLM vs AnythingLLM
description: How ForeverLM compares to AnythingLLM, the open-source app for chatting with documents on local or hosted models, on privacy, models, MCP, sources, sync, and learning.
---

# ForeverLM vs AnythingLLM

AnythingLLM, from Mintplex Labs, is an open-source (MIT) app for chatting with your documents. It comes as a free desktop app for Mac, Windows and Linux or as a self-hosted Docker server. You put documents into workspaces and ask about them with any of 40-odd model providers, including fully local models that never leave your machine, and its agents can browse, query databases and call MCP tools. It is the usual pick for people who want document chat without a vendor's cloud. ForeverLM is a different kind of tool: a library of everything you read, watch and listen to, built for learning it and remembering it.

## At a glance

| | ForeverLM | AnythingLLM |
|---|---|---|
| **Price** | 7 days free, then $19 once (no subscription); AI on your own OpenRouter key at cost, or over MCP from an assistant you already pay for | Desktop app free (an optional Pro subscription lifts the daily limits on its system-wide dictation, highlight-to-ask and autocomplete); self-hosting free; hosted cloud $50/mo Basic, $99/mo Pro, Enterprise by quote |
| **Platforms** | Native macOS app (macOS 14+), with an iPhone app and a web library | Mac, Windows and Linux desktop apps; Docker server; an Android app with on-device models |
| **Data storage** | Local SQLite + files in your private iCloud container, CloudKit sync | Local folders on your machine, or your own server; no built-in sync between devices |
| **AI models** | Any model through your own OpenRouter key, or Claude, ChatGPT, Gemini or Grok over MCP | 40+ providers (OpenRouter among them) plus fully local models: built in, Ollama or LM Studio |
| **MCP** | An MCP server: Claude, ChatGPT and other assistants work in your library | An MCP client: its agents call other MCP servers; it is not a server itself |
| **Sources** | Papers with their PDFs, articles, books, podcasts (follow shows, full transcripts), YouTube, X posts, meetings; reading lists and Apple Podcasts arrive on their own | Files you add (PDF, Word, PowerPoint, Excel, EPUB, Markdown, images, audio and video transcribed), website crawls, YouTube transcripts, GitHub and GitLab repositories, Confluence, Obsidian vaults |
| **Retention** | Weekly Schedule, cards drafted as you finish sources, and a review dialogue saved per source | None: no flashcards, quizzes or spaced repetition |
| **Outputs** | Audio overviews, reports whose claims link to their passages, courses, paper walkthroughs, explainers, Pages | Chat answers, generated documents, agent results; text to speech and dictation |

*Checked against anythingllm.com, docs.anythingllm.com and the Mintplex-Labs/anything-llm repository (release 1.17.0) in October 2026. Check [anythingllm.com](https://anythingllm.com) for current plans.*

## Where AnythingLLM is better

- **Fully local and open source.** With a local model nothing leaves your machine, and the MIT-licensed code can be read, changed and self-hosted for a whole team. ForeverLM's AI runs through OpenRouter or your assistant.
- **Every desktop platform.** Mac, Windows, Linux, and a Docker server for a team. ForeverLM is Mac-centered.
- **Agents and connectors.** Web browsing, SQL, the file system, Gmail, Calendar and Outlook skills, no-code Agent Flows, scheduled jobs, and any MCP server as a tool.
- **Free to start.** The desktop app is free and needs no account.

## Where ForeverLM is better

- **Built for learning, not only retrieval.** AnythingLLM answers questions about your documents. ForeverLM also schedules what you take in, drafts cards as you finish sources, and runs a review dialogue in which a tutor who has read the whole source checks that you understood it. See [Why Quizzing?](/why-quizzing)
- **Sources arrive on their own, in full.** Reading lists, Apple Podcasts episodes with full transcripts, papers with their PDFs and metadata, X bookmarks, YouTube likes and meeting transcripts land in the library without being uploaded to a workspace.
- **One library on every Apple device.** It syncs through your iCloud to your other Macs, the iPhone app and the web library. AnythingLLM's desktop app keeps its data on one machine.
- **Works from the assistant you already use.** ForeverLM is an MCP server, so Claude, ChatGPT, Gemini or Grok can search your library, add to it and run your reviews from their own chat.
- **Study outputs.** Audio overviews, reports whose every claim links to its passage, courses, walkthroughs of a paper's figures and spoken explainers, made from your notebook's sources.
- **Gemini Notebook moves in whole.** Paste a notebook's link and its sources, chats and notes arrive as a ForeverLM notebook ([Importing a Gemini Notebook](/studio#importing-a-gemini-notebook)).

## Which should you choose?

Choose **AnythingLLM** if privacy means local models on your own hardware, you're on Windows or Linux, or you want a self-hosted document chat with agents for a team.

Choose **ForeverLM** if you're on a Mac and want a library that gathers what you read, watch and hear, syncs across your Apple devices, and helps you remember it.
