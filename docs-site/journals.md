---
layout: doc
title: Feeds
---

# Feeds

::: warning Feeds is switched off for now
The current app has no Feeds pane in Settings, checks no feeds and offers no suggestions, and the chat has no feed tools. Feeds you already follow stay on your Mac and come back when Feeds does. This page describes how it works when it is on.
:::

Follow the sites you read — journals, blogs, newsletters, preprint listings — and ForeverLM reads their new articles and posts against your notebooks. The ones that fit are offered inside the notebook — you decide whether each becomes a source. Nothing is added to your library until you say so.

## Following a feed

Paste a site's home page or its RSS link to follow it. Any site with an RSS or Atom feed works:

- a Substack or other newsletter — `https://www.astralcodexten.com`
- a Medium publication — `https://netflixtechblog.com`
- a WordPress, Ghost or personal blog — `https://simonwillison.net`
- a preprint listing — `https://rss.arxiv.org/rss/q-bio.SC`
- a journal — `https://www.nature.com/nrm` or `https://www.nature.com/nature.rss`
- a subreddit — `https://www.reddit.com/r/longevity/`

Paste several at once, one per line, and click **Follow**. ForeverLM finds the feed the page advertises, and when a page advertises none it tries the places blogs keep their feed (`/feed`, `/rss`, `/feed.xml`, `/atom.xml`, `/index.xml`), so the home page is almost always enough. If a site hides its feed somewhere unusual, paste the feed link itself.

Each feed is checked about twice a day, and right away when you follow it. Unchanged feeds cost nothing; a feed's row shows when it was last checked and any error the site returned. **Check now** re-fetches every feed.

## Which notebooks are watched

Every active notebook is watched, including one you create later. Nothing to configure.

Each notebook is described to the matching step by what you have written in it: the title, the standing instructions, the research questions, and a sample of the sources already in it. The more precisely the notebook says what it is about, the sharper the suggestions. A notebook about "mitochondrial quality control in ageing muscle" gets the cristae paper and the blog post dissecting a new mitophagy result, not every cell-biology paper or science post of the week.

A blog post is judged on the same terms as a paper: what matters is whether its subject serves the notebook, not what kind of publication it is. Housekeeping — open threads, subscription drives, corrections, tables of contents, link roundups — is not suggested.

## Answering a suggestion

Open the notebook and its **Sources**. New matches wait at the top under **New from your feeds**, each with the site or journal, the date, the title, and one sentence on why it fits. Click the title to read it in your browser.

- **✓ Add** imports the item through the same path a pasted link takes — a paper's PDF is fetched, including through your own publisher login in ForeverLM's reader; a blog post or newsletter issue becomes an article — and adds it to the notebook.
- **✕ Dismiss** removes the suggestion for this notebook. The same item is never offered to that notebook again. Another notebook it matched keeps its own suggestion.

The notebook overview's Sources card shows how many suggestions are waiting.

## Being told

When a check finds matches while ForeverLM is open, a short message appears in the window. To hear about it when ForeverLM is in the background, turn on **Notify me when an article matches**; the banner names the notebook and opens its sources when clicked. It is off unless you turn it on.

## Cost

Matching is one AI call per batch of up to forty new items, paid by your OpenRouter key and listed in the **Activity** list under the sidebar's OpenRouter button as *Feed Article Matching*. Its model follows your Background default, which has no Settings pane; ask the chat to change it (`set_ai_task_settings`).

## What stays on this Mac

Followed feeds and pending suggestions live on the Mac that follows them. An item you add becomes an ordinary source and syncs to every device like any other.
