---
layout: doc
title: Board
---

# Board

The Board is your own to-do board: cards in columns, **To do**, **In progress** and **Done**, plus any lists you add. Use it for anything you are working on, whether or not it is about a source, and for planning your day.

Find **Board** in the Space's sidebar, under Notebooks, or keep it on the icon strip like any other place.

## Lists

**New list** at the end of the columns adds a list of your own; it sits between In progress and Done. Its **⋯** menu renames it, moves it left or right among your lists, or deletes it. Deleting a list that still holds cards asks first, and its cards go with it. Once there are more columns than fit, the Board scrolls sideways. A notebook's Tasks board has the same lists, and a team notebook's lists are the whole team's.

## Cards

Type in **Add a card** at the foot of any column but Done and press Return; the field stays ready for the next one. **New Card** at the top of the Board puts the cursor in To do.

Drag a card to another column, or to a different place in its column. The circle on a card moves it one column on (from one of your lists, that is Done), and Done wraps back to To do, so a card ticked by mistake reopens with one more click. Right-click a card to move it to any column or list, or to delete it.

## Taking a card into a chat

For an idea that needs an answer, hover a card and click the speech bubble, or right-click it and choose **Chat About This**. A fresh chat opens with the card's words ready under the composer; send it when you like. You can also drag a card onto an open chat, which adds its words after what you have typed. Once you send, the card shows a chip with the chat's name, and that chip (or **Open Chat** in the card's menu) brings the chat back. The link follows the card to your other devices.

A card has a title, notes, an optional due date, and can point at a source or a Page. Moving a card into Done stamps when you finished it; moving it out clears the stamp.

## Planning the day

**Today** shows what belongs to today: cards in progress, cards due today or overdue, and cards you finished today. The count beside it is what is still open. A card you add or drop into To do while Today is showing is due today, so it stays in view. **All** shows every card.

Search filters the cards by their title and notes, in either view.

## Over MCP and on the web

The Board is one notebook named **Board**, and its cards are that notebook's tasks. An assistant connected over MCP reads and changes them with `list_notebook_tasks`, `create_notebook_task` and `update_notebook_task`, leaving out `notebook_id` to list or add the Board's cards (or passing the Board's `notebook_id` from `list_notebooks`). A chat in ForeverLM, including the chat on a book or paper, can add a card the same way when you ask it to put something on your board; give a card `due_date` to put it on a day. The same cards appear in that notebook's **Tasks** section in the [Web Library](/web-library). The Board is synced like any notebook, so it is the same on your other devices. It is not shared with a team: a team keeps its tasks on its own notebooks (see [Teams](/teams)).
