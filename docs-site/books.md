---
layout: doc
title: Books
---

# Books

ForeverLM treats books differently from articles and papers. A book is split into its chapters, and each chapter is a source of its own, so you read, listen to and review a book a chapter at a time.

## Adding a Book

On the Library's **Books** tab, choose **Add Book…**, or drop the file on the tab: a PDF, an EPUB, or a DRM-free Kindle book. ForeverLM copies it into your library, which syncs it through your iCloud, and splits it into chapters. An EPUB keeps its own chapters; a PDF is split by your **Book Chapter Splitting** model (on the **Tasks** tab of **Settings → Background**), which reads the PDF's outline. If the model finds no chapters in a PDF, the import stops and says so. An assistant connected over MCP can send an EPUB with `import_epub`.

**Why one source per chapter:**
- Your AI assistant gets more focused context when the source covers one topic
- You can work through chapters as you read, rather than the whole book upfront

## Reading a Book

A book opens at the chapter you pick, where you left it, and reads as one book: scroll past the end of a chapter and the next one follows; scroll up past its start and you are in the one before. On the Mac this holds for a book imported from a PDF and one imported from an EPUB; on iPhone and iPad it holds for an EPUB book, while a PDF book's chapters open one at a time.

- The Reader's title and position ("6 of 31") follow the chapter you are in, and so does everything that belongs to a chapter: its reading position, how far you got, notes and highlights you make, and the chat you start about a passage.
- **Contents** lists every chapter and jumps to the one you choose: on the Mac choose **Contents…** from the Reader's **⋯** menu, on iPhone and iPad tap the list button in the Reader's toolbar.
- On the Mac, Find searches the whole book. A link inside the book — the contents page, an endnote and its way back — scrolls to what it names.
- On iPhone and iPad the chapters come from iCloud as you reach them, so the next one may take a moment to appear the first time.

## Hiding or Removing a Book

Select a book in the Books list and press Delete, or right-click its cover, then choose **Hide Book**. Every chapter leaves the list together; nothing is deleted, and hiding is visual only, so chat, search and reviews still draw on the book. The foot of the Books list then shows a quiet **N hidden books** row, which opens Hidden Items, where a book comes back with one click of **Unhide**. Selecting several covers and pressing Delete offers **Hide N Books**.

The same confirmation offers **Remove Book from Library**, which forgets the book but leaves its files in iCloud, with a short undo. To delete the files as well, use **Remove Book** in the cover's right-click menu and choose **Remove & Delete Files**.

## Tips

- **Skip appendices and references:** Work through only the chapters you're actively reading.
