---
layout: doc
title: Courses
---

# Courses

A course in ForeverLM is a path through related sources: lecture videos, papers, book chapters and your own lecture PDFs, with a quiz after each lecture. The sources stay in your library under their own types, so a lecture video is also listed under **YouTube** and a paper under **Papers**; the course lays them out in order.

## Courses and their notebooks

A course is its own thing, not part of a notebook. Every course is in the Space, in its **All** list beside your notebooks and pages and under **Courses** in its sidebar, as a card: its cover, where it comes from, and how far you are. Click a card to open the course's page, laid out the way Khan Academy lays out a unit:

- A card per lecture, with its video, its assigned reading, any notes, slides or problem sets, and its quiz.
- A checkpoint quiz every few lectures, and a course test at the end.
- At the top, your progress and **Continue**, which opens whatever is next.

Everything you have finished carries the same green check: a lecture you watched, a reading you read, a quiz you passed. Finished rows are drawn a little lighter, and the next thing to do is highlighted.

A notebook can follow a course: its sources, and every lecture the course gains later, join the notebook, and the course's page can open beside the notebook's chat. **⋯ › Link to Notebook** makes a notebook you already have follow the course, **⋯ › Make Study Notebook** makes a new one named after it that holds its sources, and **Unlink from** stops one following (it keeps the sources it holds). The page says "Linked to" the notebooks that follow it, under its title. Deleting or merging a notebook never changes a course.

Click a lecture or reading to open it in the Reader beside the course, so the path stays in view while you watch. Right-click a row for more: **Show in Sources**, **Write Quiz** on a lecture, the papers a lecture only cites under **Papers**, and **Remove from Course**. The course's own actions are in the **⋯** menu at the top of its page, or in its card's right-click menu. A hidden course waits under **Hidden** at the bottom of the Courses list, with **Show** to bring it back.

### Finish a quiz to go on

A quiz holds back what comes after it until you finish it: once every question is answered or skipped, what follows opens, whatever the score. The score still says how you did: three in four questions right (all three in a three-question quiz) is a pass, and you can answer a missed question again in the quiz's chat to raise it. A question you skip counts as not right. Lectures after a quiz you haven't finished show a lock, and when a video would play the next lecture by itself, it stops and offers the quiz instead. Anything you've already watched or read stays open. If a quiz shouldn't stand in the way, rewrite it, or remove it from its menu.

### Sharing a course

To let someone else take a course, share it with a [team](/teams) you are both in: **⋯ › Share with Team ▸** on the course's page or card. The team gets its own copy of the whole course — lectures, readings, material, quizzes and the sources behind them, files included — and every member finds it under the Space's **Courses** with a team mark. Each takes it at their own pace: their own checks, their own quiz passes, and the same locks. Your progress stays yours, and the team's copy starts at the beginning. Share it again after you change the course to bring the team's copy up to date. A team's courses are taken on the Mac; the iPhone shows only My Library.

### On iPhone

In **Sources › Courses**, tap a course to open the same page: your progress and **Continue** at the top, then each lecture with its video, readings and quiz, and the checkpoints and course test between them. The same checks and locks show, and tapping a locked row tells you which quiz opens it. Tap a quiz to take it: answer each question in your own words, typed or dictated, and each answer is checked on your chat model before the next. **Skip** at the top moves on without answering. A pass on your iPhone opens what follows on your Mac too, and the other way round. A quiz you leave halfway starts again from the first question.

## Course Structure

Courses are assembled from three types of content:

| Content type | How to add |
|---|---|
| **Book chapters** | PDF per chapter in `ForeverLM/Courses/<Course Name>/` |
| **Lecture PDFs / slides** | PDF per lecture in `ForeverLM/Courses/<Course Name>/` |
| **Video transcripts** | Text file per video in a Podcasts or course folder |

## Setting Up a Course

### 1. Create a course folder in iCloud

```
~/Library/Mobile Documents/com~apple~CloudDocs/Documents/ForeverLM/Courses/<Course Name>/
```

For example:
```
Courses/
└── CS229 Machine Learning/
    ├── lecture-01-intro-supervised.pdf
    ├── lecture-02-linear-regression.pdf
    ├── lecture-03-locally-weighted-regression.pdf
    └── problem-set-1.pdf
```

### 2. Add lecture PDFs

Copy lecture slides, problem sets, and reading PDFs into the course folder. The app scans this folder and shows each PDF as a source in the Studio sidebar.

### 3. Use with your AI assistant

Select course sources in Studio, then ask your AI assistant to:
- Explain key concepts from the lecture
- Quiz you on the material by explaining it back
- Compare ideas across multiple lectures
- Help you work through problem sets

## Importing from Canvas LMS

If your university uses [Canvas LMS](https://www.instructure.com/canvas), you can bulk-download all course materials using Claude Computer Use and drop them into your course folder.

1. Start a Computer Use session and navigate to your Canvas course
2. Ask Claude to download all lecture slides and readings
3. Move the files into your ForeverLM course folder

## Adding Video Content

For lecture videos, the workflow depends on the source:

**YouTube lectures with captions:**
Copy the video transcript into a `.txt` file and save to `ForeverLM/Podcasts/<Course Name>/`.

**Apple Podcasts lecture series:**
If the course is published as a podcast, add it in Apple Podcasts, listen to each episode, and click **Show Transcript** once per episode. ForeverLM picks up the cached transcript automatically.

### Lecture titles

A playlist's videos are often named for where they sit in a series ("Mitochondrial Cell Biology 2") rather than for what they teach. After a YouTube playlist import, ForeverLM reads each new lecture's transcript and names the lecture for its subject, keeping the video's own title when it already says what the lecture covers. The video row under each lecture still shows the video's title. To rename a course's lectures later, choose **Lectures ▸ Retitle Lectures from Content** in the course's ⋯ menu; it fetches any missing transcripts first. A lecture with no transcript keeps its title, and refreshing the playlist never undoes a title. The model is the **Lecture Titles** task.

## Importing a Teachable course

Courses sold on [Teachable](https://teachable.com), such as conference recordings, come in with their transcripts.

1. Open ForeverLM's browser, choose the **Library** profile, and sign in to the school. Signing in to your own web browser doesn't count, because ForeverLM reads the school with the sign-in made inside the app.
2. Paste any lecture's link (`…/courses/<course>/lectures/<number>`) into the source bar to add that lecture as a video. To import the whole course, ask your AI assistant to run `import_teachable_course` with the link.

ForeverLM reads the course outline from the lecture page. Each lecture with a video becomes a video on its own lecture, in the school's order. Lectures with only text, such as a CME form, are skipped.

These videos have no captions, so the transcript is made from the audio with speech-to-text. That takes a few minutes per lecture. Each transcript starts with the lecture's own text, such as the talk title and speakers.

Videos on Teachable's own hosting are supported. A school that still uses Wistia gets an error that names it.

## Generating a course

Choose **New Course ▸ Plan with Chat…** at the top of the Courses list, or type `/course <topic>` in any chat. A chat opens with "I want to make a course about " ready for you to finish. It searches your library and, if you agree, the web. Then it proposes modules with their sources and suggested videos, and revises them with you until you're happy. It builds the course only when you say so. If you agree to a video for a module, ForeverLM asks the price in its own dialog first, and the finished film sits under that module as its video.

A generated course is an ordinary course: its modules are its lectures, and **Quizzes ▸ Write Quizzes** in the course's **⋯** menu writes its quizzes.

## Reading a textbook along with a course

Choose **Lectures ▸ Add Textbook…** in a course's **⋯** menu, or drop a book from your library onto the course's card or page. Pick the book and say where you're coming from in **About you**. ForeverLM places the sections of the book worth reading for you after each lecture, with their pages and, on hover, why, and leaves out what your background already covers. Click a reading to open the chapter at its first page. See [Readings from a textbook](/studio#readings-from-a-textbook).

A lecture's quiz asks about its readings too, after the video's questions, each naming its page; a quiz written before you added the book picks them up with **Rewrite Quiz**. The quiz also knows the readings: when you miss a question, the reply links the reading that explains it next to **Rewatch**, and the last grade names the reading most worth doing. Ask it to summarize a lecture's reading and it reads exactly the planned pages.

## Tips

- **Add a whole course to a notebook:** Drag the course's card onto the notebook's row in the rail or its row in the Space. Every lecture and material is added in course order, and anything added to the course later follows into the notebook. The notebook then follows the course.
- **Add a source to a course:** Drag it from Sources onto the course's card or page, or use **Course ▸** in its right-click menu. A source that is on a course offers **Show in Course**.
- **Lecture notes > slides:** Notes usually contain more prose and context than slides alone.
- **Process lecture by lecture** as you watch, so the material is fresh.
- **Problem sets:** Add problem set PDFs too — your AI assistant can help you reason through approaches.

::: tip Naming convention
Prefix files with `lecture-01-`, `pset-01-`, etc. so they sort chronologically. The app shows sources in filename order.
:::
