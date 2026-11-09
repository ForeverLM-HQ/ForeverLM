---
name: foreverlm-figure-coverage
description: Go through the learner's ForeverLM papers and find which ones refer to Extended Data or Supplementary figures, which already carry those figures in their own PDF, and which still need them from the journal. Use when the user asks which papers are missing their Extended Data or supplementary figures, why a figure "was not found", or to audit figure coverage across the library. Replace a paper's PDF only after the learner approves.
---

# ForeverLM figure coverage

A paper's text often points at figures that are not in the main article: "Extended Data Fig. 3", "Supplementary Fig. 2", "Fig. S4". Whether the learner can look at one depends on the PDF ForeverLM holds for that paper.

- **Extended Data** (Nature and its sister journals) is printed at the back of the journal's own article PDF. A copy without it is a main-text-only file or an accepted manuscript, and the journal's PDF of the same article fixes that.
- **Supplementary figures** are almost always a separate file on the journal's site. ForeverLM keeps one PDF per paper, so these stay out of reach unless the publisher appended them to the article PDF, as some preprints do.

ForeverLM indexes the figure captions printed in each paper's PDF, Extended Data and Supplementary included. That index is free to read and runs no model. This skill compares what each paper mentions with what its PDF prints.

## Steps

1. Call `get_mcp_status`. Figure listings are read from the PDF on the learner's Mac, so a connected Mac is required. If none is connected, say so and stop.
2. **Find the papers that mention them.** Use `search_sources_keyword` with `snippets_per_source` 2 and `limit` 200:
   - Extended Data: keywords `["Extended Data Fig"]`.
   - Supplementary: keywords `["Supplementary Fig", "Supplemental Fig", "Fig. S1", "Figure S1"]`.

   Keep only papers. If the answer says more matched than it returned, sweep again with `source_ids` in batches. The passages show which figure numbers the text names. Note the highest number for each paper.
3. **Read each paper's figure index.** Call `show_source_image` with only the paper's `source_id`, leaving out `query` and `page`. It lists the paper's captioned pictures by printed label ("Extended Data Figure 2", "Supplementary Figure 1", "Figure S3") and reads the PDF again if its index was built under older rules. It is free. Work through 25 papers at a time and give the learner a progress count between batches.
4. **Sort each paper into one group:**
   - **In the PDF:** the listing carries the Extended Data (or Supplementary) labels the text names. Nothing to do.
   - **Partly in the PDF:** some labels are listed, but the text names higher numbers. Name the missing ones.
   - **Not in the PDF:** the text names them and the listing has none.
   - **No PDF or no text:** the listing is refused. Say so for each paper.

   One check before calling something missing: if the snippets show only a reference list or another paper's figures ("see Extended Data Fig. 2 of ref. 14"), the paper does not need them.
5. **Report** before changing anything:
   - Counts for each group, Extended Data and Supplementary separately.
   - A table of the papers that still need figures: title, journal, DOI if known, which figures are missing, and where they would come from (the journal's article PDF for Extended Data, the journal's supplementary file for Supplementary).
   - Papers that appear twice in the library. `find_duplicate_papers` names them; the learner may want to keep the copy that has the figures.

## Getting the missing figures

- **Extended Data missing:** offer to replace the paper's PDF with the journal's article PDF. Find its URL from the DOI (for a Nature-family article, `https://www.nature.com/articles/<article id>.pdf`). Call `attach_pdf_to_paper` with `pdf_url` only after the learner approves, one paper at a time. It replaces the stored PDF and runs the paper metadata model again, which is billed to the learner. Then call `show_source_image` again to confirm the Extended Data labels are now listed. A paywalled download fails: name the paper and let the learner download the PDF, then pass its `file_path`.
- **Supplementary missing:** list them. Do not replace the article PDF with a supplementary file: the paper would lose its own text. Do not search the web for them unless the learner asks.
- Never look for a figure on the web when it is already in the paper's PDF. `show_source_image` with `query` set to the label, or `inspect_paper_figure` for an explanation, shows it from the learner's own copy.
