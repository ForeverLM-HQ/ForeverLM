---
layout: doc
title: Books
---

# Books

ForeverLM treats books differently from articles and papers. Each chapter of a book is a source of its own, so you read, listen to and review a book a chapter at a time.

## Adding a Book

On the Library's **Books** tab, choose **Add Book…**, or drop the file on the tab: a PDF, an EPUB, or a DRM-free Kindle book. ForeverLM copies it into your library, which syncs it through your iCloud, and finds its chapters. An EPUB keeps its own chapters and stays one file, with nothing unpacked beside it. A PDF's chapters are found by your **Book Chapter Splitting** model (on the **Tasks** tab of **Settings → Background**), which reads the PDF's outline; the PDF stays one file, and each chapter is a run of its pages. If the model finds no chapters in a PDF, the import stops and says so. An assistant connected over MCP can send an EPUB with `import_epub`.

Older builds kept a PDF book as one file per chapter, and an EPUB unpacked into a folder of its files. The first launch of a build that keeps every book as one file puts each such book back together: a PDF book as its own PDF where every chapter's pages are still in it, or else the chapters joined; an EPUB by packing its folder back into the book's file. Nothing about a chapter changes, its highlights and reading position included.

A scanned PDF, whose pages are only pictures, is read first. On the Mac, OCR reads every page that carries no text of its own. Your **Scanned Page Proofreading** model, also on the **Tasks** tab, then checks each page's lines against a picture of the page and corrects what OCR misread, such as K⁺, β or 10⁻⁷. The corrected text is written into the book's PDF beneath the print, so chapters, search and highlights all work as they do in a book that came with text. The Books tab counts the pages as it reads and proofreads them. A long scan takes a few minutes, and its proofreading is billed like other background work. If proofreading fails, the import stops rather than keep text nobody checked.

**Why one source per chapter:**
- Your AI assistant gets more focused context when the source covers one topic
- You can work through chapters as you read, rather than the whole book upfront

## Reading a Book

A book opens at the chapter you pick, where you left it, and reads as one book: scroll past the end of a chapter and the next one follows; scroll up past its start and you are in the one before. On the Mac this holds for a book imported from a PDF and one imported from an EPUB, and a PDF book shows its front matter and index too; on iPhone and iPad it holds for an EPUB book, while a PDF book's chapters open one at a time.

- The Reader's title and position ("6 of 31") follow the chapter you are in, and so does everything that belongs to a chapter: its reading position, how far you got, notes and highlights you make, and the chat you start about a passage.
- **Contents** lists every chapter and jumps to the one you choose: on the Mac choose **Contents…** from the Reader's **⋯** menu, on iPhone and iPad tap the list button in the Reader's toolbar.
- On the Mac, Find searches the whole book. A link inside the book — the contents page, an endnote and its way back — scrolls to what it names.
- On iPhone and iPad the chapters come from iCloud as you reach them, so the next one may take a moment to appear the first time.

## Hiding or Removing a Book

Select a book in the Books list and press Delete, or right-click its cover, then choose **Hide Book**. Every chapter leaves the list together; nothing is deleted, and hiding is visual only, so chat, search and reviews still draw on the book. The foot of the Books list then shows a quiet **N hidden books** row, which opens Hidden Items, where a book comes back with one click of **Unhide**. Selecting several covers and pressing Delete offers **Hide N Books**.

The same confirmation offers **Remove Book from Library**, which forgets the book but leaves its files in iCloud, with a short undo. To delete the files as well, use **Remove Book** in the cover's right-click menu and choose **Remove & Delete Files**.

## Tips

- **Skip appendices and references:** Work through only the chapters you're actively reading.
