---
layout: doc
title: Plugins
---

# Plugins

Plugins are optional. On the Mac, **Plugins** is a place of its own on the icon strip, under Library, as in Codex. Its head has two tabs, **Plugins** and **Skills** (your [chat skills](/in-app-chat#skills)), and a search. The Plugins tab lists **Installed** first — every plugin that is connected, or connected and needing a reconnect — then the **Built-In** plugins and **Your Plugins** that are not connected yet. Every built-in plugin, Slack included, shows **Connected**, **Reconnect needed** or **Not connected**. Selecting one opens its page there, under a breadcrumb (**Plugins › Slack**; click **Plugins** or press ⌘[ to go back), with its controls and, under **Includes**, the ForeverLM tools it brings to a chat and to an assistant over MCP. A row's **⋯** (or a right-click) has **Open**, **Open in Other Window** and **Copy Link**, a `foreverlm://plugins/…` address that opens the page again. Settings has no Plugins. The web library has the same place on its rail for the plugins the browser can reach: Google Drive, Slack, Linear, GitHub and Notion, with the same tabs, Installed first and the same breadcrumb; skills do not reach the web yet, so its Skills tab says they are written in the Mac app.

Plugins run only after you explicitly connect them. ForeverLM never scans X or YouTube on app startup. A selected Google Drive folder refreshes on app activation, when its tab opens, or when you refresh Studio.

There is no Zotero or Paperpile plugin, by design. A paper has to live in your ForeverLM library, its PDF in your iCloud container, before the app can search it, read it aloud, chat about it, or review you on it, and a plugin that pointed at a record in another database would enable none of that. The route is a one-time import instead, from setup's Papers step or by an assistant with the ForeverLM plugin; see [Papers](/papers#coming-from-a-reference-manager).

Don't see your service here? You can [build your own plugin](/build-your-own-plugin) for any service you can reach with code — it runs on your side with ingest-only access, and an AI assistant can write it for you in minutes. The guide includes Read AI as a worked example.

## Google Drive

Use the Google Drive plugin to import meeting recordings, transcripts, and notes from folders you choose. Drive shortcuts are followed to their underlying files, so shared Meet recordings and transcript Docs import the same way as files owned directly in the selected folder.

1. In ForeverLM, open **Plugins -> Google Drive**.
2. Select **Connect Google Drive** and approve read-only Drive access in your browser, once.
3. Back in ForeverLM, choose your meeting folder from My Drive, Shared with me or a shared drive, or search for it by name.

Google's read-only Drive permission (`drive.readonly`) can read files across your Drive, but ForeverLM's plugin traverses and imports only folders you explicitly link. OAuth tokens stay in your Apple Keychain and are not sent to ForeverLM servers.

If Google Drive stops working, ForeverLM says so in an orange bar above the meeting recording and at the top of the Meetings list, with a **Reconnect Google Drive** button. Reconnecting asks Google for access once more and refreshes the folders you already linked; you do not choose them again. If the browser page goes nowhere, **Cancel** stops the wait. The linked folder refreshes when the Drive tab opens, when the app becomes active, or when you refresh Studio.

Open an imported meeting recording and select **Find mentioned papers** to read its complete transcript and notes for academic papers participants explicitly discussed or recommended. A recording-only session is transcribed on-device first. Web Studio's **Find papers** reader action opens the same source in the Mac app and starts that scan. Resolved candidates can be added through the normal paper import pipeline; incomplete mentions remain visible as unmatched rather than being silently discarded. The same workflow is available to MCP assistants through `scan_meeting_for_mentioned_papers` and `list_video_cited_papers`.

Opening a Drive meeting plays the recording in ForeverLM through the plugin's authenticated read-only session. Playing it downloads a copy into the app's disposable cache, which clears after two weeks or once it passes 2 GB. To watch with no connection, press the download arrow at the top right of the recording: the copy then stays on this Mac, outside that cache, until you choose **Remove Download** from the check mark that replaces the arrow. The copy is for this Mac only: it does not sync and is not backed up. If Google Drive supplies a transcript Doc, it appears as the **Transcript** section; if the meeting has only notes and a recording, ForeverLM transcribes the recording on-device when opened and syncs the transcript alongside the notes. Web Studio embeds the Drive preview and offers **Get transcript** when the Mac still needs to generate one.

## Calendar

The Calendar plugin makes the Mac's Calendar app your day. The **Now** chip at the bottom left of the Studio window shows today's events, and an assistant plans your day by adding events to the calendar, in a chat with `/plan` or from Claude or ChatGPT with the ForeverLM plugin.

1. In ForeverLM, open **Plugins -> Calendar** and click **Turn On**. macOS asks once whether ForeverLM may use your calendars.
2. Under **Calendars in your day**, tick the calendars that make up your day. Until you change the list, every calendar but Birthdays is shown.
3. Under **New events go to**, pick the calendar new events are added to, or leave it on the Calendar app's default.

Access is granted to this Mac by macOS and never leaves it, and the calendar choice is this Mac's. ForeverLM writes only the events you or an assistant add, and never changes an event with other people on it; you change a meeting in the Calendar app. An event ForeverLM adds shows in the Calendar app at once and reaches your phone through your calendar account. **Turn Off** stops ForeverLM reading the calendar; every event stays where it is.

### Google, Outlook and other calendars

There is no separate Google Calendar plugin: ForeverLM reads whatever the Mac's Calendar holds.

- To see a Google calendar, or a Microsoft 365, Exchange or Outlook calendar (where Teams meetings live), add the account in **System Settings -> Internet Accounts** and switch on **Calendars** for it. Its calendars then appear in the Calendar app and in ForeverLM's list.
- To see a calendar you only have a link to, such as a published Outlook calendar or a class timetable, subscribe to it in the Calendar app with **File -> New Calendar Subscription…** and its `webcal://` or `.ics` link.

A subscribed calendar is read-only, so it cannot be where new events go.

## X Bookmarks

Use the X plugin to sync saved X bookmarks into Studio as sources.

1. In ForeverLM, open **Plugins -> X**, or select the **X** tab in the Library.
2. Click **Connect**.
3. Sign in to X and approve ForeverLM's access.

After connecting, use **Sync** on the X plugin page or **Sync Bookmarks** in the Studio X tab. You can connect more than one X account: each has its own card on the plugin page, with its own **Sync** and **Disconnect** (see [X Posts](/x-posts#more-than-one-account)).

There is no developer setup: ForeverLM supplies the production OAuth client and X API access. Each person authorizes only their own X account.

## YouTube

Use the YouTube plugin to import either **Liked videos** or videos from a playlist in your account named **ForeverLM**, and to follow any number of **channels**. Connect as many Google accounts as you like: each account has its own import source, which is one of the two and can be changed later. Followed channels belong to you, not to an account, and sit alongside whatever the accounts import.

The plugin imports **metadata only** — a video's transcript (and slides) are fetched on demand the first time you open or review it, not when it's imported.

Connecting YouTube is read-only. ForeverLM reads only the source you select.

### Set Up YouTube

1. In ForeverLM, open **Plugins** on the icon strip.
2. Select **YouTube** and click **Connect**. Google asks you to grant read-only access to your YouTube account.
3. To add another account, click **Add Another Account** below the account cards and sign in with the other Google account. Each account is its own card, labelled with its channel name, with its own **Disconnect**.

There is no Google Cloud setup: YouTube signs in against ForeverLM's own OAuth client.

ForeverLM opens a temporary `127.0.0.1` callback while Google sign-in is in progress, and requests this Google scope:

```text
https://www.googleapis.com/auth/youtube.readonly
```

### Choose What to Import

After connecting an account, choose its source (each account chooses for itself):

- **Liked videos** — choose whether to import existing and future likes or only future likes. Raw transcripts are imported automatically. AI formatting is a separate opt-in because formatting a large history can use substantial credits.
- **ForeverLM playlist** — create a playlist in YouTube named exactly `ForeverLM`; all of its current videos import, and later changes stay in sync. The playlist may be public, unlisted, or private.

If more than one playlist in an account is named ForeverLM, rename the extras before selecting it. Switching an account's source keeps videos already imported and changes what ForeverLM follows from then on. When several accounts import Liked videos, they share one **Liked videos** list, and an unliked video is only archived while a single account is connected, because the list does not record which account liked a video. If Google revokes an account's access, its card says **Reconnect**; reconnecting the same channel brings back what it imported. Disconnecting an account forgets its choices.

### Follow Channels

Under **Followed channels**, paste a channel's address (`youtube.com/@handle`, `/channel/UC…`, or an older `/c/` or `/user/` link) or just its `@handle` and click **Follow**. ForeverLM resolves the channel, imports its newest 50 uploads into a group named after the channel in the YouTube tab, and from then on imports every new upload with the plugin's refresh. Nothing is archived when a video leaves a channel.

The back catalog beyond those 50 stays on YouTube; to bring an older run of videos in, add the channel's uploads or a curated playlist as a course. **Stop Following** keeps the videos already imported. Transcripts follow the same rules as other plugin imports: captions are fetched on first open, and AI formatting only runs when **Format new transcripts automatically** is on.

### Automatic Import

Turn on **Automatically import new videos** to keep every account's selected source and every followed channel fresh. One account failing does not stop the others. Followed channels are read with the first connected account's access. ForeverLM also refreshes them when you refresh the Videos tab.

::: tip Watch Later is not available
Google's YouTube Data API does not expose the Watch Later playlist, so it can't be followed. Liked videos and ordinary playlists are supported.
:::

## Slack

Slack is managed in the app. The **Slack** row in **Plugins** shows **Connected** or **Not connected**, and its pane lists every connected workspace with a switch per channel for what ForeverLM may read; a switch takes effect the moment it is flipped. **Connect Slack…** (or **Connect Another Workspace…**) opens Slack's own consent screen in a sheet over the window and finishes the connection without leaving the app, and each workspace card has **Disconnect…**, which revokes its tokens at Slack. The same page is still available at app.foreverlm.com/slack-connect for a browser you are already signed in to, and it is where a workspace connected before a newer read scope existed is asked to grant it again. ForeverLM reads Slack as you and never posts. The connection lives on your ForeverLM account, not on the Mac, so it survives restarts, updates and reinstalls; the Mac reaches it with its own Sign in with Apple session, which the app renews on its own while you keep using it. It also follows the account if Apple ever re-issues your Sign in with Apple identity, as a change to the app's Sign in with Apple grouping or developer team does: the first request from the new identity moves the workspace connections and their channel choices across, so nothing has to be connected again. The tools an assistant gets from it are listed in the [MCP Tools Reference](/mcp-tools#slack).

You can connect more than one workspace. The Slack page lists every workspace on your account; choose one to pick its channels, and **Connect another workspace…** takes you back to Slack, which asks which workspace to add. Each workspace has its own channel choices and its own permissions, so a workspace connected before a permission existed is asked to grant it on its own. A chat reads and searches across all of them at once: every channel, message and file an assistant is shown says which workspace it came from. **Disconnect this workspace** revokes that workspace's tokens at Slack and leaves the others as they are; its channel choices are kept, so connecting it again brings them back.

## Linear

Linear is connected in the **Linear** row of **Plugins**, and you can connect more than one workspace. The page lists each connected workspace as its own card, with the Linear user the reads are made as and its own **Disconnect**; **Add Another Workspace** opens Linear's consent screen in a sheet, which asks which workspace to add, and **Connect Linear** does the same when none is connected. The Linear page of your ForeverLM account at app.foreverlm.com does the same in a browser. The connection is read-only by construction. ForeverLM asks Linear for the single `read` permission, reads issues, comments, teams and projects as you when a chat asks, and never creates, edits, comments on or assigns anything; there is no code path that writes to Linear. The row shows **Connected** (or **2 connected**, and so on) or **Not connected** because the Mac asks the ForeverLM gateway that holds the grants. A chat reads every connected workspace at once and says which one each result came from; an assistant can also name one workspace. Nothing read from Linear is kept between reads. The connections live on your ForeverLM account, not on the Mac, and follow it if Apple re-issues your Sign in with Apple identity, as the Slack connection does. Linear's access tokens expire after a day; the gateway renews them on its own, and a grant Linear no longer honours is reported as a reconnect for that workspace. **Disconnect** on a workspace's card revokes that grant at Linear and forgets it, and leaves the others as they are. The tools an assistant gets from it are listed in the [MCP Tools Reference](/mcp-tools#linear).

## GitHub

GitHub is connected on the web too: the **GitHub** row in **Plugins** links to the GitHub page of your ForeverLM account, where you authorize the ForeverLM GitHub App and choose where it is installed. Where ForeverLM can read is exactly where the App is installed: an organisation you administer, or your own account; **Add an organisation** on that page opens GitHub's install chooser, and `list_github_repositories` in a chat names the same link. The connection is read-only by construction. The App's permissions are Contents, Issues, Pull requests and Metadata, all read, and there is no code path that pushes, comments, merges or changes anything on GitHub; a chat that wants to act points you at the page. The row shows **Connected** or **Not connected** because the Mac asks the ForeverLM gateway that holds the grant, and the GitHub pane says the same in a sentence with a button that reads **Connect GitHub…** or **Manage GitHub…**. Nothing read from GitHub is kept between reads. The connection lives on your ForeverLM account, not on the Mac, and follows it if Apple re-issues your Sign in with Apple identity, as the Slack and Linear connections do. GitHub's user tokens expire after eight hours; the gateway renews them on its own, and a grant GitHub no longer honours is reported as a reconnect at the same page. **Disconnect GitHub** on that page revokes the grant at GitHub and forgets it. A notebook can be linked to the repository it is about, from the **Repository** section of its About on the Mac and in Web Studio or through the Project tools (`create_project`, `update_project`), so a chat in that notebook reads the right repository without being told. The tools an assistant gets from it are listed in the [MCP Tools Reference](/mcp-tools#github).

## Notion

Notion is connected in the **Notion** row of **Plugins**, and you can connect more than one workspace. The page lists each connected workspace as its own card with its own **Disconnect**; **Add Another Workspace** opens Notion's consent screen in a sheet, where you choose the workspace and tick the pages and databases ForeverLM may read, and **Connect Notion** does the same when none is connected. What ForeverLM can read is exactly what you shared: to add a page later, open it in Notion and choose **Connections** in its **•••** menu. The connection is read-only by construction. Its capabilities are read content and read user information without email, and there is no code path that creates, edits, moves or comments on anything in Notion; a chat that wants to act points you at the page. The row shows **Connected** (or **2 connected**, and so on) or **Not connected** because the Mac asks the ForeverLM gateway that holds the grants. A chat reads every connected workspace at once and says which one each result came from; an assistant can also name one workspace. Nothing read from Notion is kept between reads. The connections live on your ForeverLM account, not on the Mac, and follow it if Apple re-issues your Sign in with Apple identity, as the Slack, Linear and GitHub connections do. A grant Notion stops honouring is renewed by the gateway on its own, and one it will not renew is reported as a reconnect for that workspace. **Disconnect** on a workspace's card revokes that grant at Notion and forgets it, and leaves the others as they are. The tools an assistant gets from it are listed in the [MCP Tools Reference](/mcp-tools#notion).
