---
layout: doc
title: Plan
---

# Plan

Plan at three scales, the way Cal Newport teaches it: a plan for the **quarter**, a plan for each **week** written with the quarter's plan in view, and each **day** planned in time blocks with the week's plan in view.

Find **Plan** in the Space's sidebar, under Board, or keep it on the icon strip like any other place.

## Quarters and weeks

**Quarter** lists the four quarters of a year (Q1 is January to March); **Week** lists the weeks of a quarter, with the quarter's own plan above them. The arrows step through years or quarters, and **This Year** or **This Quarter** brings you back. The present quarter and week are marked.

Click a quarter or a week to open its plan. The first time, it opens as a new Page laid out for the exercise:

- A quarter has **Big picture** (what the season is for, and the longer direction it serves), **Objectives** (the few things that make the quarter a success) and **Strategies and habits** (how you will get there: projects, routines, rules of thumb).
- A week links its quarter and has **This week** (what the week makes progress on, each from one of the quarter's objectives) and **Days** (a line for what each day is mainly for).

These follow how Newport describes the two plans, a quarterly plan of goals and the strategies you run, and a weekly plan written with that plan and your calendar in view. He keeps them as free text, so treat the headings as a start: write what helps. The calendar popover reads **Objectives**, **This week** and **Days**, so keep those names if you want to see them there.

A plan is an ordinary Page in your own library, so it syncs and you can write anything in it. Its title names its period, "Q4 2026" or "Week of November 2nd, 2026", so `[[Q4 2026]]` in any Page links it, and the quarter's Linked References list its weeks. Weeks run Monday to Sunday and belong to the quarter that holds their Thursday. You can plan any quarter, including one already under way.

## Days

A day is planned on your Mac's Calendar, as time blocks (see [Studio](/studio)). Planning the day reads the week's plan first, so the day serves the week.

Click the calendar glyph at the foot of the window's left edge to see the plans the day serves, under today's events: this quarter's objectives, what this week makes progress on, and what the week's **Days** say for today. Click the quarter or the week to open its plan; one not planned yet says **Plan in Chat…** and starts the chat that plans it.

## Planning with the chat

**Plan** at the top of the place opens a chat that plans with you: **Plan This Quarter**, **Plan This Week**, or **Plan Today** (**Plan Tomorrow** from the afternoon). In any chat, `/plan quarter`, `/plan week`, `/plan today` and `/plan tomorrow` do the same.

The chat reads first: for a quarter, the quarter's Page, the previous quarter's, your Goals and what you have been working on; for a week, the week's Page, its quarter's plan, last week's and your calendar. It then proposes a whole draft. Answer in your own words until it is right; only then does it write the plan into the Page (or, for a day, add the blocks to your calendar).

You don't need `/plan` for the chat to use your plans. Whenever you ask any chat to plan a week or a day, or what to work on next, it first reads the quarter's and the week's plan with `get_plan`, which shows in the chat as **Read the plan**, and says which objective or item of the week its proposal serves. Planning the day reads the week's plan, whose answer brings the quarter's objectives and the week's line for that day. Claude or ChatGPT with the ForeverLM plugin are told to do the same.

## Over MCP

An assistant reads a plan with `get_plan` (`scale` quarter or week; `create: true` makes it from its template) and writes in it with `edit_doc`. See [MCP Tools](/mcp-tools). Plans are kept in the library on your Mac, so the Mac must be open and connected.

## On iPhone and iPad

**Plan** is in the Space's list, under All: **Quarter** or **Week** at the top, the arrows in the list's header to step through years or quarters, and a tap on a quarter or a week to open its plan, made from the same template the first time. A plan you write on the iPhone is the same Page as on your Mac. Planning with the chat and planning the day are on the Mac.

## On the web

The [Web Library](/web-library) has no Plan place: plans you have made are among your Pages, where you can read and edit them.
