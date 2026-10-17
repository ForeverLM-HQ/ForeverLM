---
layout: doc
title: Board
---

# Board

The Board is your own to-do board: cards in three columns, **To do**, **In progress** and **Done**. Use it for anything you are working on, whether or not it is about a source, and for planning your day.

Find **Board** in the Space's sidebar, under Notebooks, or keep it on the icon strip like any other place.

## Cards

Type in **Add a card** at the foot of To do or In progress and press Return; the field stays ready for the next one. **New Card** at the top of the Board puts the cursor in To do.

Drag a card to another column, or to a different place in its column. The circle on a card moves it one column on, and Done wraps back to To do, so a card ticked by mistake reopens with one more click. Right-click a card to move it to any column or to delete it.

A card has a title, notes, an optional due date, and can point at a source or a Page. Moving a card into Done stamps when you finished it; moving it out clears the stamp.

## Planning the day

**Today** shows what belongs to today: cards in progress, cards due today or overdue, and cards you finished today. The count beside it is what is still open. A card you add or drop into To do while Today is showing is due today, so it stays in view. **All** shows every card.

Search filters the cards by their title and notes, in either view.

## Over MCP and on the web

The Board is one notebook named **Board**, and its cards are that notebook's tasks. An assistant connected over MCP reads and changes them with `list_notebook_tasks`, `create_notebook_task` and `update_notebook_task`, passing the Board's `notebook_id` from `list_notebooks`; give a card `due_date` to put it on a day. The same cards appear in that notebook's **Tasks** section in the [Web Library](/web-library). The Board is synced like any notebook, so it is the same on your other devices. It is not shared with a team: a team keeps its tasks on its own notebooks (see [Teams](/teams)).
