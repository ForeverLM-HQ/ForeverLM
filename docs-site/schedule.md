---
layout: doc
title: Schedule
---

# Schedule

Schedule is your plan of which sources to study on which day. Instead of keeping an endless queue of articles, papers, podcasts, books, and videos, you put specific sources on specific days and see what is still pending and what is done.

## What Schedule is for

Use Schedule when you want to:

- Plan a week of study from sources already in your library
- Spread a large backlog across manageable daily sessions
- Move sources between days as your week changes
- Track progress without treating "imported" as "learned"
- Ask an AI assistant to inspect or adjust your plan through MCP

Schedule is not a passive read/unread tracker. Opening a source records what you did, never that you finished it: a source is done only when you check it off or a review grades it.

## Planning a week

Schedule has no pane of its own: you plan in the conversation. Ask Chat, or an
assistant connected through MCP, to spread sources across the week, move one to
another day, take one off the plan, or clear a day, and it changes the plan for
you. To put a source on today yourself, right-click it in the Library and choose
**Schedule for Today**; in a notebook, a source's right-click **Schedule for…**
picks a day of this week. On the iPhone, a source's **Schedule** button does the
same.

Each scheduled item keeps its source ID, title, source type, planned date, and completion state. This makes it safe for ForeverLM and connected AI assistants to talk about the same item.

Schedule plans sources, not hours. Your day's meetings and time blocks are your Mac's Calendar, which `/plan` in Chat fills in.

## Starting today's work

When sources are planned for today, an empty chat's first suggestion says so ("3 sources planned today"). Click it for today's list: click a source to start it (it opens in the Reader with Chat beside it), click the circle in front of it to check it off, or choose **Quiz me on these** to review the whole day. On the iPhone, today's plan is a card on the home screen.

## Progress and completion

Schedule progress is based on what you did with a source, not whether you opened it. A planned source is done when:

- You check it off in today's list
- A review of it in the in-app Chat panel, or a completed MCP review session, grades it
- An assistant saves a Claude, ChatGPT, Gemini, Grok, or Edison Scientific review of it into ForeverLM, or marks it done for you

This keeps progress honest: the schedule shows what you have actually tested yourself on, not just what you skimmed.

## Using Schedule with AI assistants

When MCP is connected, your assistant can inspect and manage Schedule for you. Typical requests:

- "What should I study today?"
- "Move tomorrow's paper to Friday."
- "Create a study plan from these sources for this week."
- "Clear Wednesday and redistribute those sources."
- "Mark this reviewed source complete."

The assistant should read the current Schedule before proposing changes. MCP write operations validate source IDs and days before changing the plan.

## Sync

Schedule is stored in ForeverLM's local SQLite database and synced through CloudKit. Plans, source assignments, planned dates, completion state, and review links follow you across Macs after iCloud sync catches up.
