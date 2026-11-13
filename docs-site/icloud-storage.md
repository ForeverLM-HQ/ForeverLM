---
layout: doc
title: iCloud Storage & Privacy
---

# iCloud Storage & Privacy

ForeverLM keeps your whole library on your Mac and syncs it through your own iCloud account to your iPhone, iPad and the web library. ForeverLM servers do not store your library.

The iPhone and iPad app works with the Mac app and needs it: the Mac adds your sources and prepares their text, and the phone reads, listens, talks and reviews what arrives through iCloud. You can add a link, a PDF or scanned pages from the phone, but ForeverLM on your Mac is what fetches and prepares them, the next time it runs.

## Your library syncs with iCloud

Every library syncs with iCloud; there is no setting to turn it off. The first step of setup explains it, and **Settings → Data & Privacy → iCloud** shows how sync is doing.

- Your library shows on your iPhone, iPad and the web library, and you can share with a [team](/teams).
- The synced copy uses **your own iCloud storage**. The free 5 GB fills quickly once papers, books and audio sync, so we recommend the **200 GB iCloud+ plan**. You can upgrade under **System Settings → Apple Account → iCloud** on a Mac, or **Settings → [your name] → iCloud** on an iPhone.
- A Mac that is not signed in to iCloud keeps its library on the Mac and starts syncing once you sign in. Setup and **Settings → Data & Privacy → iCloud** say so, with a button to open iCloud settings.

### How much iCloud ForeverLM uses

**Settings → Data & Privacy → iCloud** shows how much of your iCloud ForeverLM's files take up, split into the PDFs of your papers, books and course material, the text of your sources, and the files in ForeverLM's iCloud Drive folder, which are mostly Text to Speech audio. It counts what ForeverLM can measure itself. Apple keeps the exact figure for each app, which **Manage…** beside it opens.

### When iCloud is full

When your iCloud storage runs out, iCloud refuses new uploads. ForeverLM shows a notice, and **Settings → Data & Privacy → iCloud** says that sync has paused. Nothing is lost, and nothing needs moving: your library already lives on your Mac's disk, and iCloud only carries the copy your other devices read. Your changes stay on your Mac and upload once there is room. Until then your iPhone, iPad, other Macs and the web library get nothing new, so free up iCloud space or move to a larger plan. The same pane says when the Mac is not signed in to iCloud, which also stops sync.

## ForeverLM's new iCloud store

ForeverLM keeps your library in its own, redesigned area of your iCloud account.
What you will notice:

- **One Mac uploads your library; the others join it.** The first Mac that syncs
  sends your library's records first and then your files. Your other Macs catch up
  with it, and the iPhone, the iPad and the web library show your library as it
  arrives.
- **Coming from an earlier ForeverLM.** ForeverLM moved to this store in October
  2026, when it began to be published under its own developer account. Your
  library stayed on your Mac: on that Mac, **Settings → Data & Privacy → iCloud**
  offers **Upload my library to iCloud again**, which sends it to the new store
  once. ForeverLM no longer reads or changes the iCloud data earlier versions
  wrote.
- **Files sync as part of the library.** Papers, books and other originals sync with
  no size limit, so a paper is on your iPhone and in the web library even when it is
  large. Your iCloud storage still pays for it, so the advice about the 200 GB plan
  stands.
- **More of your library works without your Mac.** The web library and the hosted
  assistant connection read your library from iCloud directly, so the web library
  can search inside your sources and an assistant can read them while your Mac is
  closed, once you have allowed it.
- **Your place stays yours.** Where you got to in a source, your highlights, cards,
  review results and Schedule are your own records, stored under your own account
  and never part of a team.
- **If your iCloud data is removed.** When you delete ForeverLM's data in iCloud
  settings, ForeverLM stops syncing, keeps your library on your Mac and offers to
  upload it again. It never uploads on its own after that.

## How sync works

The synced copy lives in ForeverLM's private area of your iCloud account, and Apple handles sync and encryption:

- **At rest**: encrypted on Apple's servers with keys derived from your iCloud account.
- **In transit**: encrypted over TLS between your devices and iCloud.
- **On device**: protected by your device passcode and the Secure Enclave.

ForeverLM servers do not store your source library.

## What's synced to iCloud

| Data | Description |
|------|-------------|
| Library records | Sources and their content, your Schedule, reviews and settings |
| Source files | The PDFs, books and audio of papers, books and articles you've added |
| Artifacts | Pages, explorable explanations and review session records |

On the Mac, the library itself is a SQLite database and flat files in `~/Library/Application Support/ForeverLM`. That copy stays on the Mac beside the one in iCloud.

## Team data

A [team](/teams) is a shared area inside the iCloud account of the person who
created it, shared with the members through Apple's iCloud sharing. Everything
shared into a team (a notebook you move into your own team, or a copy of what you
give a team someone else owns) is stored there, including the PDFs and book files
that travel with a shared source, so a team counts against the creator's iCloud
quota and against nobody else's. Members receive the team through their own
iCloud account; ForeverLM servers hold no copy of a team, its roster or its
content. Leaving a team removes it from your Macs; deleting one removes it, and
everything in it, for every member. Each member's reading progress, highlights, review results and Schedule stay in that
member's own private container and never enter the team's storage.

## What ForeverLM servers do not store

- Your source content
- Your book or article PDFs
- Your podcast transcripts
- Your review session history

There are two important exceptions for traffic you explicitly enable:

- **AI providers:** if you configure an API key or use an external AI assistant, the selected source content or prompts you send go to that provider.
- **Hosted MCP relay:** if you connect an external assistant through MCP, requests and responses pass through ForeverLM-operated Cloudflare infrastructure before reaching your Mac. The relay does not log or store request or response bodies, but it is a trusted relay and is not end-to-end private from ForeverLM infrastructure.

External-assistant MCP traffic passes through ForeverLM-operated Cloudflare infrastructure in transit. The relay does not log or store request or response bodies.

## Offline access

On the Mac, your library is ordinary files on its own disk, so every source opens offline, and **Optimize Mac Storage** does not remove it.

On an iPhone or iPad, a source's text and files come down from iCloud, so one you haven't opened on that device before may need a connection the first time.

## Deleting your data

Your library is on your Mac and in your own iCloud account, so you have full control:

1. **Delete the app**: removes the app from that device. On a Mac, the library in `~/Library/Application Support/ForeverLM` stays until you delete that folder. iCloud data remains until you remove it.
2. **Delete from iCloud**: go to **Settings > [Your Name] > iCloud > Manage Storage > ForeverLM** and delete the data.

No need to contact ForeverLM or request data deletion. You own it all.
