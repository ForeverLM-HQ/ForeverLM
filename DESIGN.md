# DESIGN.md — ForeverLM design rules

Rules for what the learner sees, on every client (Mac, iPhone, web). The general UI rules (quiet chrome, the list head, hover washes) are under "UI design" in `AGENTS.md`; this file holds the rules about how content is drawn. Each rule carries its reason in one line.

## App addresses are never shown as text

- **A `foreverlm://…` address is never visible to the learner as plain text.** `foreverlm://source/<id>`, `foreverlm://doc/<id>`, `foreverlm://notebook/<id>` and any other in-app address are for links, drags and storage, not for reading. Wherever text that may hold one is shown (a card's notes or title, a chat reply, a Page, a quiz, a board card, a notification, a tooltip), it is rendered: a markdown link draws as its title, and a bare address draws as the thing it names (its title, a chip, a thumbnail), and a click opens it in the app. Why: an id hash is meaningless to a learner and makes the surface look broken.
- **Render first, edit on request.** A field whose text may carry links reads as rendered text and turns into an editable field only when the learner clicks to edit it. Drawing stored markdown straight into a `TextField` shows the raw `[title](foreverlm://source/…)`.
- **Use the app's renderers, not a new one.** Inline text goes through `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))` in a `Text`, so the window's `openURL` (`BrowserWorkspace.handle`) routes the link; richer text goes through `ChatMarkdownView`, which turns a source link into its smart chip. If neither fits, extend them.
- **A link with no title is resolved, not printed.** When only a bare address is known, look up the item's title; if the item is missing, say so in words ("Missing source") rather than show the address.

## Text never widens its container

- **Long content wraps or truncates inside the width it is given.** A long unbroken string (a URL, an address, a hash) must not push a card, column or row wider than its frame, where it spills under its neighbour. Give text that can hold one `.frame(minWidth: 0, maxWidth: .infinity)` and `.fixedSize(horizontal: false, vertical: true)`, and check a layout with such a string in it. Why: one long card's notes once widened the whole Board's To do column under In progress.
