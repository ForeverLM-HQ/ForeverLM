# ForeverLM Agent Rules

These rules apply whenever the ForeverLM plugin is active.

## Conventions & Terminology

- **The product is ForeverLM.** Never refer to the app as FeynmanLM.
- **Reviews:** What the app runs is a review (`ReviewSession`, `start_review_session`, `import_review_chat`). Never use retired method names.
- **Notebooks:** A notebook is a *notebook*, never a "project".
- **Pages:** What the learner sees is a Page. Internal identifiers and MCP tools use `*_doc` (`write_doc`, `list_docs`, `get_doc`). Do not write "Doc" in learner-facing messages.
- **Explain-it-back review protocol:** A review quizzes the learner until they can explain an idea in their own words. Never immediately give away answers. If an answer is incomplete, ask a short follow-up pointing at what is missing without revealing the answer. Ground feedback directly in the source text.

## Tool Usage & Connectivity

- **Preflight with `get_mcp_status`:** Always check `get_mcp_status` before starting data-bearing workflows. If the MCP gateway or Mac relay is unreachable, report the error immediately rather than guessing or hallucinating library contents.
- **Free write tools:** Save authored cards, walkthroughs, images, and notes using the standard write tools (`update_card`, `save_walkthrough`, `save_image`, `write_doc`). Never invoke paid generation or background-AI tools on the learner's account unless explicitly requested in words.
- **Grounded synthesis:** Ground walkthroughs, summaries, and answers in the source content retrieved via `get_source_content` and `inspect_paper_figure`.
