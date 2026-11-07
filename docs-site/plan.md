---
layout: doc
title: Plan
---

# Plan

Plan at three scales, the way Cal Newport teaches it: a plan for the **quarter**, and each **week** and **day** put on your calendar with the quarter's plan in view.

## The quarter

Find **Plan** in the Space's sidebar, under Board, or keep it on the icon strip like any other place. It lists the four quarters of a year (Q1 is January to March); the arrows step through years, **This Year** brings you back, and the present quarter is marked. You can plan any quarter, including one already under way.

Click a quarter to open it in place: its objectives, each in a colour, and its weeks under them. Click **Objectives** (or right-click the quarter) to open its plan. The first time, it opens as a new Page with three headings:

- **Big picture**: what the season is for, and the longer direction it serves.
- **Objectives**: the few things that would make the quarter a success.
- **Strategies and habits**: how you will get there, from projects and routines to rules of thumb.

Newport keeps these plans as free text, so the headings are only a start: write what helps. The plan is an ordinary Page in your own library, so it syncs, and its title, "Q4 2026", links it from any Page as `[[Q4 2026]]`.

## The week and the day

A week's plan is the week on your Mac's Calendar: the blocks of focused work, on the days they belong to, around what is already there. Move them around as the week goes; nothing else records the week. A day works the same way, as time blocks (see [Studio](/studio)).

In **Plan**, an open quarter lists its weeks, Monday to Sunday. Each week shows its seven days as small bars, filled by the hours of its blocks in the colours of the objectives they serve, and how many blocks and hours it gives the quarter. Click a week to see its days and their blocks, and click a day to open it in **Day**. A block counts toward the quarter when its notes name one of the quarter's objectives or link its plan, as the blocks the chat plans with you do; meetings and everything else on the calendar show in grey. Each objective also shows the hours its weeks have given it so far.

Click the calendar glyph at the foot of the window's left edge to see today's events and, under them, this quarter's objectives. Click the quarter to open its plan; one not planned yet says **Plan in Chat…** and starts the chat that plans it.

## Planning with the chat

**Plan** at the top of the place opens a chat that plans with you: **Plan This Quarter**, **Plan This Week**, or **Plan Today** (**Plan Tomorrow** from the afternoon). In any chat, `/plan quarter`, `/plan week`, `/plan today` and `/plan tomorrow` do the same.

The chat reads first: for a quarter, its plan, the previous quarter's, your Goals and what you have been working on; for a week or a day, the quarter's plan and your calendar. It then proposes a whole draft and says which objective each piece serves. Answer in your own words until it is right; only then does it write the quarter into its Page, or put the week's or the day's blocks on your calendar.

You don't need `/plan` for this. Whenever you ask any chat to plan a week or a day, or what to work on next, it first reads the quarter's plan with `get_plan`, which shows in the chat as **Read the plan**. Claude or ChatGPT with the ForeverLM plugin are told to do the same.

## Over MCP

An assistant reads the quarter's plan with `get_plan` (`create: true` makes it from its template) and writes in it with `edit_doc`; it plans a week or a day with `get_calendar_events` and `create_calendar_event`. See [MCP Tools](/mcp-tools). Plans are kept in the library on your Mac, so the Mac must be open and connected.

## On iPhone and iPad

**Plan** is in the Space's list, under All: the year's quarters, with arrows in the list's header to step through years, and a tap on a quarter to open its plan, made from the same template the first time. A plan you write on the iPhone is the same Page as on your Mac. Planning with the chat is on the Mac.

## On the web

The [Web Library](/web-library) has no Plan place: quarter plans you have made are among your Pages, where you can read and edit them.
