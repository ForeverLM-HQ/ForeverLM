---
layout: doc
title: Books
---

# Books

ForeverLM treats books differently from articles and papers. Instead of processing an entire book at once, it works chapter by chapter, letting you build your source library gradually as you read.

## Where to Store Books

Save book PDFs to this iCloud Drive folder:

```
~/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM/Books/
```

In Finder, this appears under **iCloud Drive → Documents → ForeverLM → Books**. Create the folder if it doesn't exist.

Organize books into subfolders by title or author if you have many:

```
Books/
├── Deep Learning (Goodfellow)/
│   ├── deep-learning-ch01-intro.pdf
│   ├── deep-learning-ch02-linear-algebra.pdf
│   └── deep-learning-ch03-probability.pdf
├── The Pragmatic Programmer.pdf
└── Thinking Fast and Slow.pdf
```

## Chapter Splitting

Long books need to be split into chapter-sized chunks. The app works best with PDFs in the 20–80 page range per source.

**Why split by chapter:**
- Your AI assistant gets more focused context when the source covers one topic
- You can process chapters as you read, rather than the whole book upfront

**Splitting a PDF on Mac:**

Open the book PDF in Preview, then:
1. Go to **View → Thumbnails** to see the page sidebar
2. Select the pages for a chapter (click + Shift-click to select a range)
3. Drag the selected pages to the Finder folder, or use **File → Export as PDF**

Alternatively, use `pdftk` in Terminal:

```bash
# Extract pages 45–78 (Chapter 3) from a book
pdftk book.pdf cat 45-78 output deep-learning-ch03-probability.pdf
```

## Adding a Book Chapter

1. **Save the chapter PDF** to the Books folder in iCloud Drive.
2. **Open ForeverLM.** The chapter PDF appears in your Studio queue automatically.
3. **Select the chapter** to load its content. It's now available to your AI assistant via MCP.

## Reading a Book

A book opens at the chapter you pick, where you left it, and reads as one book: scroll past the end of a chapter and the next one follows; scroll up past its start and you are in the one before. On the Mac this holds for a book imported from a PDF and one imported from an EPUB; on iPhone and iPad it holds for an EPUB book, while a PDF book's chapters open one at a time.

- The Reader's title and position ("6 of 31") follow the chapter you are in, and so does everything that belongs to a chapter: its reading position, how far you got, notes and highlights you make, and the chat you start about a passage.
- **Contents** lists every chapter and jumps to the one you choose: on the Mac choose **Contents…** from the Reader's **⋯** menu, on iPhone and iPad tap the list button in the Reader's toolbar.
- On the Mac, Find searches the whole book. A link inside the book — the contents page, an endnote and its way back — scrolls to what it names.
- On iPhone and iPad the chapters come from iCloud as you reach them, so the next one may take a moment to appear the first time.

## Hiding or Removing a Book

Select a book in the Books list and press Delete, or right-click its cover, then choose **Hide Book**. Every chapter leaves the list together; nothing is deleted, and hiding is visual only, so chat, search and reviews still draw on the book. The foot of the Books list then shows a quiet **N hidden books** row, which opens Hidden Items, where a book comes back with one click of **Unhide**. Selecting several covers and pressing Delete offers **Hide N Books**.

The same confirmation offers **Remove Book from Library**, which forgets the book but leaves its files in iCloud Drive, with a short undo. To delete the files as well, use **Remove Book** in the cover's right-click menu and choose **Remove & Delete Files**.

## Tips

- **Rename chapters descriptively:** `deep-learning-ch03-probability-and-information-theory.pdf` gives the AI better context than `chapter-03.pdf`.
- **Skip appendices and references:** Process only the chapters you're actively reading.
- **Process gradually:** Add chapters as you read them — no need to do the whole book upfront.
