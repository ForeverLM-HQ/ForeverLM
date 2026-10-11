# CLAUDE.md — ForeverLM

**Read [AGENTS.md](AGENTS.md) first.** It holds the rules for this repo: the product's
words (a *review*, a *notebook*, a *Page*), storage and migrations, AI routing, sync,
UI, and how to verify a change. This file only adds what a coding agent needs on top.

- **The tree names no person and no company.** `scripts/check-open-tree.sh` checks it,
  and `--staged` is what the pre-commit hook runs. Attribute a product decision as
  `(product owner, YYYY-MM-DD: "…")` and use made-up names in tests.
- **Verify before you commit.** Read the diff, run the focused unit tests for what you
  touched, and say in the commit message what you ran and what is still to watch.
- **Commits are authored by the repo's configured identity.** Do not change it.
- **Other people's changes are not yours to undo.** The checkout often carries edits from
  another session; commit your own files only.
