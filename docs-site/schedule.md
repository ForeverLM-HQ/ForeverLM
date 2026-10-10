---
layout: doc
title: Schedule
---

# Schedule

Schedule turns your source library into a weekly learning plan. Instead of keeping an endless queue of articles, papers, podcasts, books, and videos, you can assign specific sources to specific days and see what is pending, reviewed, and complete.

## What Schedule is for

Use Schedule when you want to:

- Plan a week of study from sources already in Studio
- Spread a large backlog across manageable daily sessions
- Move sources between days as your week changes
- Track progress without treating "imported" as "learned"
- Ask an AI assistant to inspect or adjust your plan through MCP

Schedule is not a passive read/unread tracker. A source is complete only after it has a linked review session.

## Planning a week

Add sources to Schedule from Studio, then assign them to days in the week. The
complete week remains visible so you can compare daily workloads without opening
each day separately. You can drag sources onto a day, move scheduled items
between days, remove sources from the plan, or clear a day when you need to
re-plan.

Each scheduled item keeps its source ID, title, source type, planned date, and completion state. This makes it safe for ForeverLM and connected AI assistants to talk about the same item.

## Starting today's work

Open Schedule and look at the current day. Pending sources are the sources you still need to study or review. Open a source from Schedule to read it, listen to it with Text to Speech when available, or start a review in the Chat panel.

If the source has not been reviewed yet, Schedule treats it as pending until a completed or linked review session is attached to that source.

## Progress and completion

Schedule progress is based on review completion, not whether you opened the source. A source can be marked done when it has a linked review from one of these places:

- The in-app Chat panel
- A completed MCP review session
- A saved Claude, ChatGPT, Gemini, Grok, or Edison Scientific review link

This keeps progress honest: the schedule shows what you have actually tested yourself on, not just what you skimmed.

## Using Schedule with AI assistants

When MCP is connected, your assistant can inspect and manage Schedule for you. Typical requests:

- "What should I study today?"
- "Move tomorrow's paper to Friday."
- "Create a study plan from these sources for this week."
- "Clear Wednesday and redistribute those sources."
- "Mark this reviewed source complete."

The assistant should read the current Schedule before proposing changes. MCP write operations validate source IDs and days before mutating the plan, and completion still requires a linked review.

## Sync

Schedule is stored in ForeverLM's local SQLite database and synced through CloudKit. Plans, source assignments, planned dates, completion state, and review links follow you across Macs after iCloud sync catches up.
