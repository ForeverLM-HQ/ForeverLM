---
layout: doc
title: Articles
---

# Articles

ForeverLM automatically surfaces articles you've saved to your browser's reading list, making them available for AI-assisted learning via MCP.

## Supported Browsers

Reading list sync works with **Safari**, **Google Chrome**, and **Brave**. The app discovers saved articles from all three browsers automatically on macOS.

## How Articles Are Discovered

**Safari Reading List (automatic):**
The app reads the Reading List in `~/Library/Safari/Bookmarks.plist` and adds new items to your queue automatically. macOS protects that file, so if the scan is blocked, add ForeverLM in **System Settings** → **Privacy & Security** → **Full Disk Access** (use the **+** button; macOS does not list it until you do), turn it on, and relaunch the app.

**Chrome & Brave Reading List (automatic):**
The app reads reading list entries from Chrome and Brave's local data. No special permissions are needed. Just add articles to your reading list in either browser and they'll appear under **Articles** in the Library.

**Choosing browsers and how far back to go:**
Setup's Articles step asks one question, which browser you use: Safari, Chrome, Brave, or several. The Mac's default browser is marked Recommended. Pages saved in the last 30 days come in first, and everything you save after that arrives on its own. Every page that comes in is fetched and cleaned up by AI once, so a long backlog costs more. Change the browsers, or how much of what is already saved to bring in (**Everything**, the **Last 30 days**, or **Only new saves**), in **Settings → Sources → Reading Lists**, or from chat (`sources.reading_list_browsers` and `sources.reading_list_import_window`). A wider choice imports the pages it now reaches right away.

**Via MCP:**
Your AI assistant can add articles using the `add_source` tool.

**From a read-later app:**
A one-time import, described [below](#coming-from-a-read-later-app).

## Coming from a Read-Later App

If your saved articles live in Readwise Reader, Instapaper, Raindrop, Pocket, Omnivore or a similar app, bring them over once. Setup's Articles step has **Coming from Readwise, Instapaper or Pocket?**, which opens a page with **Choose Export…**. Choose the file the app exported, or the unzipped export folder:

- **Readwise Reader:** Settings → Export, then the CSV.
- **Instapaper:** Settings → Export, then the CSV or HTML file.
- **Raindrop:** Settings → Backups, then the CSV or HTML file.
- **Pocket, Omnivore and others:** the export you downloaded, as a file or an unzipped folder.

ForeverLM reads any CSV with a link column, any bookmarks HTML file (the format browsers export), JSON exports whose records carry a link, and plain lists of links. Each link becomes an article with its title, the date you saved it, and whether you had archived it; the full text is then fetched in the background, one article at a time. Links already in your library are not added twice, and items a reader only showed you from a feed, which you never saved, are left out. It is a one-time copy: nothing keeps syncing with the other app afterwards, and it is never changed.

## Going Back to What You Saved

**To Read** is the one list of what you saved and have not finished, newest first, under **Today**, **Yesterday**, **This Week** and **Earlier**. It holds web pages, papers and X posts you saved one at a time, from every browser's reading list, the share sheet, a bookmark import or a link you added. Podcasts, YouTube, books, courses and meetings are not in it: they arrive by the dozen and have their own tabs.

- **Mac:** the **Library** is one list. An unread source has its title in black (white in dark mode), and a read one is grey with a closed book at its end; click the mark to switch it. Each row also shows how many passages wait to be followed up (a flag) and how many cards it has kept, so a source with neither left to do reads quietest.
- **iPhone and iPad:** **To Read** is a chip in the **Library** row at the foot of Home. Tap a row to read it, or swipe it right to mark it read.

A source drops off the list when you finish it, mark it read, hide it or remove it. One you have only started stays on it.

## Using Articles with AI

Once an article appears in Studio:

1. **Select** the article. The app fetches and displays the full text.
2. The content is now available to your AI assistant via MCP.
3. Ask your AI to explain key concepts, quiz you on the material, or compare it with other sources.

## When a Publisher Blocks the Fetch

Some sites answer ForeverLM's background fetch with a bot check instead of the article, and the row then reads **Blocked by a publisher security check**. Nothing from the check is stored, so the article is not silently replaced by a few lines of boilerplate.

Open the article anyway. The reader is a real browser session, so the check usually clears there and the page loads. Once it has, ForeverLM saves that page as the article: the text becomes the source's content, the HTML is archived for offline reading, and the row stops showing the block. The background fetch also waits a few seconds for a check that clears on its own before giving up, so many of these never reach the row at all.

## Tips

- Articles with dense, mechanism-heavy content (research blogs, technical deep-dives) work best for explain-it-back learning.
- Use semantic search to find articles related to a concept across your library.
