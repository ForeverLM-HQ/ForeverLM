---
layout: doc
title: X Posts
---

# X Posts

ForeverLM lets you sign in with one or more X (formerly Twitter) accounts and sync their saved bookmarks as sources.

::: tip
X setup also appears in the [Plugins](/external-plugins#x-bookmarks) guide.
:::

## Signing In

You do not need an X Developer account, API subscription, or client ID.

1. Open **Plugins -> X** on the icon strip, or select the **X** tab in the Library.
2. Click **Connect**.
3. Sign in to X and approve ForeverLM's access.

ForeverLM uses its production X app and OAuth 2.0 PKCE. Your authorization is limited to your own X account and can be revoked from either ForeverLM or X.

## More Than One Account

**Plugins -> X** shows each connected account on its own card, with when it last synced. Click **Add Another Account** to connect a further one: X signs you in as whichever account your browser is signed in to there, so sign in to the other account on x.com first. Signing in again as an account that is already connected refreshes it instead of adding a second card.

**Sync** and **Disconnect** on a card act on that account only, and an account that needs signing in again says **Reconnect needed** while the others keep syncing. Disconnecting an account stops its bookmark sync; the posts it already brought in stay.

## Syncing Bookmarks

Tap **Sync Bookmarks** in the X sidebar tab to sync every account, or **Sync** on one account's card. New bookmarks are fetched and added to your source queue. Each post appears with the full tweet text, author, and any included URLs.

## Posting

Your AI assistant can post to X through the [MCP connection](/mcp-tools) when you ask it to. With one account connected it posts as that account; with several, it has to say which one.

## Tips

- Bookmark threads and long-form note tweets for the richest source material.
- Short one-liner tweets rarely have enough substance for meaningful learning.
