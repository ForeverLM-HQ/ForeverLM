---
layout: doc
title: Papers
---

# Papers

Academic papers (from arxiv, Nature, Science, bioRxiv, and similar journals) get special treatment in ForeverLM. Save a paper to your Safari, Chrome, or Brave reading list and the app picks it up automatically, detecting it as a paper by URL and fetching the full PDF whenever possible.

## How Papers Are Detected

ForeverLM classifies a source as a paper in two steps:

**Step 1 — URL detection.** The URL is checked against known academic domains:

- arxiv.org, nature.com, science.org, cell.com
- biorxiv.org, medrxiv.org, plos.org
- pubmed.ncbi.nlm.nih.gov
- and other major journal publishers

**Step 2 — LLM classification.** Journals like Science and Nature publish both research papers and shorter editorial content (news articles, commentary, perspectives). These live on the same domain, so URL detection alone can't tell them apart. Before downloading a PDF, ForeverLM sends the URL and title to a lightweight LLM call on your Background text model (the **Source Classification** task in **Settings → Background → Tasks**) that classifies the source as a paper or article. Editorial content is automatically moved to the Articles tab.

This also works in the other direction: if a web article turns out to be an academic paper (e.g., a preprint hosted on a personal blog), the LLM reclassifies it after fetching the content.

## Adding a Paper

**From your reading list:**
Save the paper's abstract or landing page to your browser's reading list (Safari, Chrome, or Brave). The app picks it up automatically, as far back as you chose in setup or in **Settings → Sources → Reading Lists** (see [Articles](/articles#how-articles-are-discovered)).

**Manual paste:**
In a notebook, paste the paper's URL or DOI into **Add sources** and choose **Add link**: the paper joins your library and the notebook in one step. In ForeverLM's Browser, **Add to Sources** saves the page you are reading.

**Via MCP:**
Your AI assistant adds a paper with `import_paper_from_url` (a URL or DOI) or `import_local_pdf_as_paper` (a PDF on your Mac). Either way the paper shows in Papers as soon as its PDF is in, as processing until its metadata is read. `add_source` is for non-paper sources. Given a notebook's `notebook_id`, `import_paper_from_url` files the paper in that notebook as well, and a paper already in your library joins it instead of being imported again.

**From Zotero, Paperpile, Mendeley or another reference manager:**
A one-time import, described [below](#coming-from-a-reference-manager).

**From Chat:**
When the [in-app Chat](/in-app-chat#web-search) brings up a paper your library does not hold, it offers to add it. Ask, and it finds the DOI or publisher page itself and imports the paper through the same pipeline as a pasted URL.

## Coming from a Reference Manager

ForeverLM does not connect to Zotero, Paperpile or Mendeley, and that is a decision rather than a gap. Everything the app does with a paper depends on the paper itself living in your library: the PDF sits in your iCloud container, so its text is extracted and searchable, Chat can quote it, Text to Speech can narrate it on your Mac and iPhone, a review can test you on it, and it syncs to every device. A plugin that pointed at a record in another database would enable none of that. It would give you a list of titles and a lock screen.

So instead of a live plugin there is a one-time move. Bring the papers over once and they are ForeverLM papers from then on. Your reference manager keeps doing what it is good at, citations and bibliographies, and is never modified.

**In setup.** The Papers step asks where your papers live: **Zotero**, **Another reference manager**, **PDFs on this Mac**, or **I don't have any yet**, and each answer opens a page with one way in. Zotero is offered only when it keeps its library on this Mac (in `~/Zotero`, or wherever Zotero's settings moved it); its page says how many papers it holds and how many have a PDF, and **Import from Zotero** brings them over in one click. For any other reference manager, **Choose Export…** on its page takes any of these, or several at once:

- **Zotero:** the Zotero folder in your home folder, the one holding `zotero.sqlite` and `storage/` (Zotero → Settings → Advanced → Files and Folders shows where it is). Zotero can stay open.
- **Paperpile:** export BibTeX into the `Paperpile` folder that Paperpile syncs to Google Drive, then choose that folder, so the export's file paths resolve to the PDFs in `All Papers`.
- **Mendeley:** export your library as BibTeX and choose the file. Mendeley Reference Manager's export carries no PDFs, so those papers are added by DOI and the normal PDF fetch completes them.
- **EndNote, JabRef, ReadCube and others:** a BibTeX or RIS export, or a folder of PDFs.

ForeverLM reads the library read-only, copies each PDF into the synced Papers folder, and adds papers that have no PDF by DOI so the normal PDF fetch can try to complete them. A paper already in your library is matched by DOI or title and is not added twice; missing authors or journal are filled in from the export. The metadata and cleanup models then work through the new papers in the background as they do for any other paper.

**Highlights and notes come too.** The highlights, underlines and comments you made in Zotero's reader are brought over with each paper, in their colors, and so are its notes pinned to the page. For any other app, ForeverLM reads the highlights and notes saved inside the PDF file itself. That covers PDFs marked up in Preview or Acrobat, and a PDF your reference manager saved or exported with its annotations. A reference manager that keeps annotations only in its own database or in the cloud leaves them out of the file, and ForeverLM cannot see them there. This works for any PDF you add, not only in a library import: drop an annotated PDF into Papers and its marks arrive with it.

Each one becomes an ordinary ForeverLM highlight. It shows in the reader and the notes list, you can search it, a review takes its note into account, and it syncs to your other devices. A note pinned beside the text is attached to the nearest line, and each color becomes the nearest of ForeverLM's five markers. Importing the same library or PDF again adds nothing twice, and a passage you have already highlighted in ForeverLM keeps your mark. Nothing is written back to the other app or the original file.

**With an AI assistant.** The [ForeverLM plugin](/setup-mcp#claude-code-plugin) includes a paper-library-migration skill: ask Claude Code, or another assistant that has the plugin, to move your reference library into ForeverLM. It reads the reference manager on your Mac, imports each paper through the same pipeline, and reports what landed, what was already there, and what it skipped. The Mac app must be running, because the import happens on your Mac.

## Following a Paper's References

A paper's reference list is the reading list its authors wrote for you. When a paper is open in the reader, choose **Find Cited Papers** from the reader's **⋯** menu (a paper's context menu in the sidebar offers it too). ForeverLM reads the reference list off the paper's PDF, looks each entry up in Crossref and OpenAlex, and lists the papers it found in the same panel: **Add to Library** imports one through the normal paper pipeline, so it gets a PDF, metadata, and cleanup like any other paper, and **Dismiss** waves it off. Papers you already have are marked as such rather than offered again, and an entry that could not be matched to a record is shown as unmatched so you can search for it by hand. Decisions persist and sync, so a paper dismissed on one Mac stays dismissed on the other, and a dismissed paper can be restored from the panel's Dismissed section.

Nothing is read until you ask. Reading the list is a background AI call per stretch of references plus a free catalog lookup per entry, with at most eight paid web searches for entries the catalogs could not place, so a long reference list can take a minute; once it finishes, the menu item becomes **Cited Papers** and says how many are waiting to be added, and opens the panel, whose **Read references again** reads the list once more. The model behind it is the **Paper Reference Extraction** task, on the **Tasks** tab of **Settings → Background**; the chat can change it too (`set_ai_task_settings`).

## Reading a Figure Beside its Legend

A journal often prints a figure on one page and its legend on another: overleaf, a few pages on, or at the end of a preprint. When a paper is open in the reader, choose **Figure Legends** from the reader's **⋯** menu and a column opens beside the PDF with every figure's legend. It follows the page you are on: the figures drawn on that page are marked and their legends scroll into view, wherever the legend itself is printed. Click a figure's name to go to its page. The legends are read from the paper's own PDF, free, with no model call, and a figure whose legend the paper does not print shows "No legend found". Figure Legends shares the reader's side column with Levels and Linked References, so opening one closes the others. It is on the Mac, in the reader and in a Source Reader window, for papers open as a PDF; the web does not have it yet.

## How PDF Loading Works

When you add a paper, ForeverLM tries to get the full PDF automatically:

1. **Direct fetch**: downloads the PDF (works for open-access papers on arxiv, bioRxiv, PLOS, etc.)
2. **PubMed Central (PMC)**: fetches the full text if available in PMC

A paper in ForeverLM is a PDF. When every route fails, the paper waits in **Papers that need attention** until a PDF turns up: attach one, or, for a paper you can read on the publisher's site, save it from the page yourself as described below. ForeverLM never reads a publisher's page as the paper on its own.

When a PDF is fetched, it is saved with the paper in your library and syncs through your iCloud to your other devices.

## Dealing with Paywalled Papers

### Open access (no action needed)

Papers on arxiv, bioRxiv, medrxiv, PLOS, and other open-access repositories are fetched automatically.

### PubMed Central (PMC)

If a paper is in PMC (even if the publisher's version is paywalled), ForeverLM detects this and fetches the PMC version automatically.

### Other paywalled publishers

For papers behind paywalls:

1. **Download the PDF** from your institutional access.
2. **Drop it on the paper's row** in Papers, or choose **Attach PDF File…** from the row's right-click menu.

### Read online, but no PDF (Nature and others)

Some subscriptions let you read a paper on the publisher's site but never offer the PDF. Open the paper in ForeverLM: when the publisher refuses the PDF, the reader shows the publisher's page instead of a lock screen. The reader is a real browser session, so sign in to the publisher there if you have not already. Once the page in front of you is the paper, click **Save Paper from Page** in the reader's toolbar (it is in the reader's menu too). ForeverLM stores the page's text as the paper's content, asks the publisher for the PDF once more with your signed-in session, and when the file is still refused prints the page you are reading to a PDF and saves that as the paper's file. The text goes through the same Source Content Cleanup and metadata extraction as a downloaded PDF, so search, chat, review sessions, and Listen work on it, and the reader shows the PDF from then on.

This is your choice each time; ForeverLM never takes a publisher's page for a paper on its own. A page that is the publisher's access wall, or only the abstract and front matter, is refused with a message saying so, so sign in first and make sure the whole paper is on the page.

Signing in matters once, in ForeverLM's reader: your browser's login does not carry over, because the app has its own cookie store. Once you have signed in there, every ForeverLM fetch uses it, including the PDF download, so **Download PDF** in the reader's toolbar may simply get the file, which is the better outcome when the publisher offers one.

Some publishers go further and hand the PDF only to a browser: nature.com, for one, answers any other client with a JavaScript check, whatever cookies it carries. When ForeverLM's own download comes back with a page instead of the file and you have opened that publisher in the reader, the app asks again through the reader's own browser session, in the background, exactly as if you had clicked Download PDF there. The same checks apply as for any downloaded file: it has to be a PDF, a supplementary file such as a Reporting Summary is never taken for the paper, and a paper that already has its PDF is left alone. This is how a paper your subscription covers comes down on its own once you have signed in to the publisher in the reader, and how **Recheck all** on paywalled papers, in the Papers tab or over MCP, recovers it later. A publisher you have never opened in the reader is not tried this way, because there is no session to use.

When an AI assistant runs the bulk PDF download over MCP, papers that fail in a paywall-shaped way (access denied, login or payment required, an HTML page served instead of a PDF, or no open-access copy found anywhere) are automatically marked as paywalled so they stop being retried. Attaching a PDF clears the marker, and the assistant can also clear it with `set_source_paywall_status`.

The same applies when an AI assistant imports a single paper by URL or DOI (`import_paper_from_url`): if the publisher blocks the PDF, the paper is still added, marked paywalled, with the title, authors, venue, year, and DOI the landing page and Crossref provide. It appears in the Papers tab with the paywall recovery options, ready for you to attach the PDF, and a later paywall recheck can pick up a free copy. Only transient failures, such as a network error or a 404, leave nothing behind.

## Tips

- **Search one field only:** the sources search reads a paper's title, authors, journal, year, DOI and address, and also finds papers whose text contains the words. To search titles alone, start the query with `title:` — `title:reverse electron transport` lists only papers with that phrase in the title. `author:`, `journal:`, `year:`, `doi:` and `site:` work the same way, in every sources tab.
- **Preprints are ideal**: arxiv and bioRxiv papers are always freely accessible.
- **Long papers:** the app reads the whole PDF, however long, including methods and resource tables printed after the references.
- **Scanned PDFs:** prefer native PDFs over scans for better text extraction.
