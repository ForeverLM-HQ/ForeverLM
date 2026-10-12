---
layout: doc
title: Podcasts
---

# Podcasts

ForeverLM can extract transcripts from Apple Podcasts episodes, making your podcast listening available as sources for AI-assisted learning.

::: warning Apple Podcasts is the supported podcast source
Podcast discovery and episode identity come from **Apple Podcasts**. Apple Podcasts caches its transcripts as files on your Mac, which ForeverLM reads directly when available.

Other podcast players — **Spotify**, Overcast, Pocket Casts, and the rest — are not supported, because they don't make transcripts easily available: transcripts either don't exist or stay locked inside the player, with no local files or public API another app could read.

If you normally listen elsewhere, you can still get an episode into ForeverLM: find it in Apple Podcasts and open its transcript view once, and ForeverLM will pick it up from there.
:::

## How Episodes Are Discovered

ForeverLM queries your local Podcasts database for episodes you have played since the start of 2026 and checks whether a transcript is available.

This requires **Full Disk Access** in macOS System Settings → Privacy & Security → Full Disk Access. Setup asks for it before the Podcasts step: **Open System Settings**, add ForeverLM with the **+** button (macOS does not list it until you do), turn it on, then **Relaunch ForeverLM**.

## Choosing Shows in Setup

Setup's Podcasts step lists every show you follow in Apple Podcasts and every show with an episode you played, with how many episodes would come in, before anything is imported. Tick the shows to bring in; every show starts ticked.

- **Ticked:** the episodes you play arrive, with their transcripts.
- **Unticked:** the show's episodes never become sources. The same as **Never Import** in a show's menu.

**Untick All** and **Tick All** set every show at once. The import starts when you press Continue, so a show you turned away is never fetched. To bring a show in but keep it out of the list, chat, search and reviews (its transcripts are then not cleaned up by AI, so it costs nothing), choose **Hide** from the show's menu in the sidebar later.

## Transcript Availability

Apple Podcasts downloads transcripts on demand. They are **not** available by default. To make a transcript available:

1. Open **Apple Podcasts** on your Mac.
2. Navigate to the episode.
3. Click **Transcript** in the episode detail view. This triggers Apple to download and cache the transcript locally.

Once cached, ForeverLM can extract it. If Apple has no accessible transcript, the episode remains available for transcript recovery.

Hidden shows and episodes do not use the automatic transcript worker. Unhiding one starts its pending transcript work again.

## Hiding and the Whole Show

A single episode hides from its right-click menu (**Hide**) and comes back from Hidden Items. Hiding one episode is visual only: it stays in your knowledge, so chat, search and reviews still use it. Hiding a show (right-click an episode, **Hide *show***) is stronger: its episodes leave the list and are kept out of chat, search and reviews as well, so a show you never asked for stays quiet. Unhide one episode from Hidden Items and that episode is back in both. Nothing is deleted either way. The bottom of the Podcasts list then ends with a quiet **N hidden shows** row; click it for the Hidden Items page, where each show unhides in one click and expands to its hidden episodes. While you are searching, that row instead says how many hidden items match, so a search that comes up short because the show was hidden says so.

Unhiding a show brings its episodes back, including any that another device hid one by one while the show was hidden. An episode you hid yourself before hiding the show stays hidden. A show that is not hidden but has hidden episodes appears in Hidden Items with a **Show all** button that reveals them together.

Discovery imports the episodes you listened to. For a show you want in full, right-click any of its episodes and choose **Follow *show*: Import All Episodes**. Every episode Apple Podcasts holds locally for that show is added now, played or not, and from then on each new episode that appears in Apple Podcasts is imported on the next sync, whether or not you have played it. Episodes already in your library are left alone, and everything queues for transcripts like any other episode. **Unfollow *show*** stops the automatic import and keeps what was added. Following a show in ForeverLM assumes you follow it in Apple Podcasts too, since that is where the episode list comes from. In the Podcasts list, an episode you have played sorts by when you last played it, and one you have not played sorts by its publish date, so a whole catalog falls into episode order.

## Private and Member Feeds

A paid subscription usually arrives in Apple Podcasts as a private feed with a longer name — "The Peter Attia Drive - Private Subscriber Feed (🔓 for …)". Apple transcribes only the public catalog, never a private feed, so an episode from a member feed has no transcript of its own. ForeverLM resolves it to the same episode in the show's public edition: the public show is the one the feed's name begins with, and the episode is the one with the same number, or the same title when the feed carries no numbers. The row keeps its place in your library and takes the public episode's transcript. An episode with no public twin — a members-only bonus, an AMA the public feed carries only as a preview — reports **No matching episode found on Apple Podcasts**, and **Transcribe Audio** remains available for it.

An episode's show notes are never its content. A podcast row that only holds the episode's web page — an older import did this for private feeds — is not ready; it queues for its transcript like any other episode.

If Apple says an episode has no accessible transcript, ForeverLM automatically searches YouTube when the YouTube plugin is connected. A show's upload is often titled differently from its episode, so ForeverLM looks first at the videos the episode's own web page links, then at the show's YouTube channel for uploads from around the episode's release (once an earlier episode's transcript came from that channel), and only then searches YouTube. It proposes video matches in the reader, saying when one is linked from the episode's page or on the show's channel, but never chooses one itself. Confirm that a video is the same episode before selecting **Use Transcript**; only then are its captions attached to the Apple Podcasts source. An AI assistant connected over MCP does the same with `find_podcast_on_youtube` and, once you confirm the video, `import_podcast_youtube_transcript`, which also takes a YouTube link you found yourself.

## Transcript Cleanup

During ingestion, ForeverLM uses the model selected for **Transcript Formatting** to make podcast transcripts easier to study:

- Adds paragraph breaks at natural topic transitions
- Replaces diarized speaker IDs with real names when the episode evidence is clear
- Removes confidently identified sponsor messages and ad reads, including their promotional transition lines

The model identifies exact spans rather than rewriting Apple Podcast transcripts. ForeverLM deletes a proposed ad only when both boundaries match one unambiguous, bounded passage; uncertain passages remain. Editorial discussion of a company or product, guest affiliations, disclosures, credits, and substantive content are preserved.

When a confirmed YouTube video supplies a missing podcast transcript, the same podcast-specific ad cleanup runs while the captions are formatted for readability.

## Using Podcasts with AI

Once transcripts are extracted, they appear as sources in Studio. Select them and your AI assistant can:

- Summarize key points from the episode
- Quiz you on specific claims or mechanisms discussed
- Compare ideas across multiple episodes or with your other sources

In the [in-app Chat](/in-app-chat#citing-a-moment), a citation into an episode can carry the moment the passage was spoken (`[2 · 12:34]`); clicking it scrolls the transcript to that segment. In a [Memory review](/in-app-chat#memory-review), tell the tutor "keep podcasts quick" to have every podcast reviewed with the recall question only.

## Tips

- Episodes with long-form interviews and technical discussions work best.
- Make sure to open the transcript view in Apple Podcasts **before** trying to extract.
- Podcast sources use local file paths, ensuring they're tied to the actual transcript you listened to.
