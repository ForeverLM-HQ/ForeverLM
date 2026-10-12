// The text half of the chat renderer: Markdown in, repaired Markdown out.
//
// Everything here is a pure function over strings, which is what lets the Mac
// app's WebView and Web Studio run the identical pipeline and lets the node
// tests exercise it without a DOM. The DOM half lives in `chat-dom.js`.
//
// These repairs exist because chat text is a language model's streaming output,
// not authored Markdown. A reply arrives one delta at a time, so the renderer
// routinely sees a half-written display-math block, a checklist whose items are
// glued onto one line, or a table whose header carries a title cell. Repairing
// at render time keeps the saved response byte-exact: persistence still owns
// the provider's words, so a later renderer can reinterpret them losslessly.

/// Repairs display-math framing before Markdown sees it. Models sometimes
/// stream a display block with a bare `[` opener, stop after the leading slash
/// of `\]`, or leave a multiline environment open. Passing that text straight
/// to markdown-it consumes the bracket escape and exposes every TeX command as
/// prose. This bounded line parser only claims bracketed blocks that contain
/// clear TeX syntax, leaves code fences and ordinary bracketed prose alone, and
/// gives KaTeX a complete temporary block while streaming.
export function normalizeLatexDisplayBlocks(markdown) {
  const lines = String(markdown ?? "").replace(/\r\n?/g, "\n").split("\n");
  const output = [];
  let fenceMarker = null;

  const fenceFor = (line) => line.trim().match(/^(`{3,}|~{3,})/);

  const hasLatexEvidence = (bodyLines) => {
    const body = bodyLines.join("\n");
    return /\\(?:begin|text|frac|dfrac|tfrac|sqrt|left|right|operatorname|mathrm|mathbf|mathit|vec|hat|bar|overline|underline|sum|prod|int|lim|rightarrow|leftarrow|leftrightarrow|Rightarrow|Leftarrow|infty|alpha|beta|gamma|delta|theta|lambda|mu|sigma|omega)\b/.test(body)
      || /(?:[_^]\s*\{|\\[a-zA-Z]+\s*[=<>+\-*/])/.test(body);
  };

  const repairedBody = (bodyLines) => {
    // A single final slash is invalid TeX. Inside display math it is the
    // truncated form of the `\\` row separator models intend.
    const repaired = bodyLines.map((line) => (/(^|[^\\])\\\s*$/.test(line) ? `${line}\\` : line));
    const environmentStack = [];
    const environmentToken = /\\(begin|end)\{([A-Za-z*]+)\}/g;
    for (const line of repaired) {
      environmentToken.lastIndex = 0;
      let match;
      while ((match = environmentToken.exec(line)) !== null) {
        if (match[1] === "begin") environmentStack.push(match[2]);
        else if (environmentStack.at(-1) === match[2]) environmentStack.pop();
      }
    }
    while (environmentStack.length > 0) repaired.push(`\\end{${environmentStack.pop()}}`);
    return repaired;
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const fence = fenceFor(line);
    if (fence) {
      if (fenceMarker && fence[1][0] === fenceMarker) fenceMarker = null;
      else if (!fenceMarker) fenceMarker = fence[1][0];
      output.push(line);
      continue;
    }
    if (fenceMarker) {
      output.push(line);
      continue;
    }

    const opener = line.trim();
    if (!["\\[", "[", "$$"].includes(opener)) {
      output.push(line);
      continue;
    }

    const body = [];
    let closeIndex = -1;
    for (let candidate = index + 1; candidate < lines.length; candidate += 1) {
      const close = lines[candidate].trim();
      if (["\\]", "]", "$$", "\\"].includes(close)) {
        closeIndex = candidate;
        break;
      }
      body.push(lines[candidate]);
    }

    // An unfinished streamed block has no closer yet. Claim the remaining lines
    // only when their commands prove this is TeX, then synthesize a display
    // close for this paint. A future stream update is reparsed.
    if (closeIndex < 0 && !hasLatexEvidence(body)) {
      output.push(line);
      continue;
    }
    if (closeIndex >= 0 && opener === "[" && !hasLatexEvidence(body)) {
      output.push(line);
      continue;
    }

    output.push(`${line.slice(0, line.indexOf(opener))}$$`);
    output.push(...repairedBody(body), "$$");
    index = closeIndex >= 0 ? closeIndex : lines.length;
  }

  return output.join("\n");
}

/// A source link the model wrote twice: once as a bold title, once as the link
/// right after it. The card that replaces the link already shows the title, so
/// the bold copy would read as a stutter.
export function collapseRepeatedSourceTitleLinks(markdown) {
  return String(markdown ?? "").replace(
    /\*\*([^*\n]+)\*\*\s+\[([^\]\n]+)\]\(([^)\n]+)\)/g,
    (match, boldTitle, linkedTitle, href) => {
      const normalizedBoldTitle = boldTitle.replace(/\s+/g, " ").trim();
      const normalizedLinkedTitle = linkedTitle.replace(/\s+/g, " ").trim();
      const isSourceLink = href.toLowerCase().startsWith("foreverlm://source/");
      if (!isSourceLink || normalizedBoldTitle !== normalizedLinkedTitle) return match;
      return `[${linkedTitle}](${href})`;
    },
  );
}

/// Models sometimes emit literal `<br>` or `<p>` tags, escaped or not, in text
/// they were asked to write as Markdown. Turn them into the line breaks they
/// mean, and collapse the runs of blank lines that leaves behind.
export function normalizeModelLineBreaks(markdown) {
  return String(markdown ?? "")
    .replace(/\r\n?/g, "\n")
    .replace(/&lt;br\s*\/?\s*&gt;/gi, "\n")
    .replace(/<br\s*\/?\s*>/gi, "\n")
    .replace(/&lt;\/?p\s*&gt;/gi, "\n")
    .replace(/<\/?p\s*>/gi, "\n")
    .replace(/\n{3,}/g, "\n\n");
}

function tableCells(line) {
  let value = String(line ?? "").trim();
  if (!value.includes("|")) return [];
  if (value.startsWith("|")) value = value.slice(1);
  if (value.endsWith("|")) value = value.slice(0, -1);
  return value.split("|").map((cell) => cell.trim());
}

function tableRow(cells) {
  return `| ${cells.join(" | ")} |`;
}

function isTableDivider(line) {
  const cells = tableCells(line);
  if (cells.length < 2) return false;
  return cells.every((cell) => /^:?-{3,}:?$/.test(cell.replace(/\s/g, "")));
}

/// A table whose header row carries the table's own title in its leading cells
/// has one more column than its divider, so markdown-it rejects the whole
/// block. Lift the title out as a bold line above a well-formed table.
export function normalizeMarkdownTables(markdown) {
  const lines = String(markdown ?? "").replace(/\r\n?/g, "\n").split("\n");
  const output = [];

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const nextLine = lines[index + 1];

    if (nextLine && isTableDivider(nextLine)) {
      const headerCells = tableCells(line);
      const dividerCells = tableCells(nextLine);
      const extraCellCount = headerCells.length - dividerCells.length;

      if (extraCellCount > 0 && headerCells.length >= 3) {
        const title = headerCells.slice(0, extraCellCount).join(" | ").trim();
        const tableHeaderCells = headerCells.slice(extraCellCount);
        const startsWithIndexColumn = /^(#|no\.?|item)$/i.test(tableHeaderCells[0] ?? "");

        if (title && tableHeaderCells.length === dividerCells.length && startsWithIndexColumn) {
          if (output.length > 0 && output.at(-1).trim() !== "") output.push("");
          output.push(`**${title}**`, "", tableRow(tableHeaderCells), tableRow(dividerCells));
          index += 1;
          continue;
        }
      }
    }

    output.push(line);
  }

  return output.join("\n");
}

// Models also glue the next question onto the last checklist item
// ("- [x] late-start significance**Q3 (dosing):** What is..."), which buries
// the question inside a checkbox row. When a task item's text runs into a bold
// "Label:" run with a sentence after it, keep the checklist text on the item
// and push the question out as its own paragraph.
function pushTaskItem(output, indent, box, content) {
  const glued = content.match(/^(.*?\S.*?)\s*(\*\*[^*]+:\*\*\s*\S[\s\S]*)$/);
  if (glued && glued[1].trim().length >= 12 && glued[2].trim().length >= 12) {
    output.push(`${indent}- ${box} ${glued[1].trim()}`, "", glued[2].trim());
    return;
  }
  output.push(`${indent}- ${box} ${content}`);
}

/// Models emit review checklists as GFM task lists (`- [ ] concept`), but
/// markdown-it does not parse them, so the brackets render literally. Worse,
/// models routinely glue several checkboxes onto one line
/// ("...matters- [ ] Rapamycin..."), which collapses the whole checklist into a
/// single list item. Split every checkbox onto its own `- [ ]` line here;
/// `renderTaskListCheckboxes` turns the markers into styled boxes after
/// markdown-it runs.
export function normalizeTaskLists(markdown) {
  const lines = String(markdown ?? "").replace(/\r\n?/g, "\n").split("\n");
  const token = /(?:[-*+][ \t]*)?\[[ xX]\][ \t]+/g;
  const output = [];

  for (const line of lines) {
    if (!/\[[ xX]\]/.test(line)) {
      output.push(line);
      continue;
    }

    const matches = [];
    let match;
    token.lastIndex = 0;
    while ((match = token.exec(line)) !== null) {
      matches.push({
        start: match.index,
        end: token.lastIndex,
        box: match[0].match(/\[[ xX]\]/)[0],
      });
    }

    const indent = (line.match(/^[ \t]*/) ?? [""])[0];

    if (matches.length === 0) {
      output.push(line);
      continue;
    }

    if (matches.length === 1) {
      // A lone checkbox mid-sentence is incidental prose, not a task item.
      if (matches[0].start === indent.length) {
        pushTaskItem(output, indent, matches[0].box, line.slice(matches[0].end).replace(/[ \t]+$/, ""));
      } else {
        output.push(line);
      }
      continue;
    }

    for (let part = 0; part < matches.length; part += 1) {
      const contentStart = matches[part].end;
      const contentEnd = part + 1 < matches.length ? matches[part + 1].start : line.length;
      pushTaskItem(output, indent, matches[part].box, line.slice(contentStart, contentEnd).replace(/[ \t]+$/, ""));
    }
  }

  return output.join("\n");
}

/// Emphasis a model wrote without the spaces CommonMark needs. `word**bold**`
/// has no left-flanking delimiter run, so markdown-it prints the asterisks.
/// Insert the space the model meant, tracking open/close state so the pair
/// stays balanced, and copy code spans through untouched.
export function normalizeTightMarkdownEmphasis(markdown) {
  const input = String(markdown ?? "");
  let output = "";
  let index = 0;
  let strongOpen = false;
  let emOpen = false;

  const isWhitespace = (value) => !value || /\s/.test(value);
  const isPunctuation = (value) => !!value && /[!"#$%&'()+,\-./:;<=>?@[\\\]^_`{|}~]/.test(value);

  const backtickRunLength = (at) => {
    let count = 0;
    while (input[at + count] === "`") count += 1;
    return count;
  };

  const copyCodeSpan = () => {
    const runLength = backtickRunLength(index);
    const delimiter = "`".repeat(runLength);
    const closeIndex = input.indexOf(delimiter, index + runLength);
    if (closeIndex < 0) {
      output += input.slice(index);
      index = input.length;
      return;
    }
    output += input.slice(index, closeIndex + runLength);
    index = closeIndex + runLength;
  };

  while (index < input.length) {
    if (input[index] === "`") {
      copyCodeSpan();
      continue;
    }

    if (input.startsWith("**", index)) {
      const previous = output.length > 0 ? output.at(-1) : "";
      const next = index + 2 < input.length ? input[index + 2] : "";
      const canBeStrongDelimiter = strongOpen
        ? previous && !isWhitespace(previous)
        : next && !isWhitespace(next);

      if (!canBeStrongDelimiter) {
        output += "**";
        index += 2;
        continue;
      }

      if (!strongOpen && previous && !isWhitespace(previous) && !isPunctuation(previous)) output += " ";
      output += "**";
      index += 2;
      if (strongOpen && next && !isWhitespace(next) && !isPunctuation(next)) output += " ";
      strongOpen = !strongOpen;
      continue;
    }

    if (input[index] === "*" && input[index - 1] !== "*" && input[index + 1] !== "*") {
      const previous = output.length > 0 ? output.at(-1) : "";
      const next = index + 1 < input.length ? input[index + 1] : "";
      const canBeEmDelimiter = emOpen
        ? previous && !isWhitespace(previous)
        : next && !isWhitespace(next);

      if (!canBeEmDelimiter) {
        output += "*";
        index += 1;
        continue;
      }

      if (!emOpen && previous && !isWhitespace(previous) && !isPunctuation(previous)) output += " ";
      output += "*";
      index += 1;
      if (emOpen && next && !isWhitespace(next) && !isPunctuation(next)) output += " ";
      emOpen = !emOpen;
      continue;
    }

    output += input[index];
    index += 1;
  }

  return output;
}

const MATH_TOKEN_PREFIX = "@@FOREVERLM_MATH_";

/// Math has to survive Markdown. `x_1` is a subscript to TeX and an emphasis
/// run to CommonMark, and `\[` is an escaped bracket. Lift every math span out
/// before markdown-it runs and put the exact source back afterwards, so KaTeX
/// sees what the model wrote rather than what Markdown made of it.
///
/// A single `$` is also a price. A reply that quotes rates ("$69 self / $132
/// assisted") would otherwise pair its dollar signs into inline math, and in a
/// table the span swallows the cell pipes and the rows after it. Inline `$…$`
/// therefore follows pandoc's rule: the opener has text right after it, the
/// closer has text right before it and no digit after it. The closer is the
/// first unescaped `$` on the same line, as it is in TeX, so a price that
/// fails the rule stays literal and scanning resumes at the next dollar.
export function protectMath(markdown) {
  const input = String(markdown ?? "");
  const output = [];
  const segments = [];
  let index = 0;

  const isWhitespace = (value) => !value || /\s/.test(value);

  const findClosingDollar = (from) => {
    for (let closeStart = from; closeStart < input.length; closeStart += 1) {
      const character = input[closeStart];
      if (character === "\n") return -1;
      if (character !== "$" || input[closeStart - 1] === "\\") continue;
      const previous = input[closeStart - 1];
      const next = input[closeStart + 1] ?? "";
      if (next === "$" || isWhitespace(previous) || /\d/.test(next)) return -1;
      return closeStart;
    }
    return -1;
  };

  const nextCandidate = (from) => {
    const candidates = [
      { start: input.indexOf("$$", from), open: "$$", close: "$$" },
      { start: input.indexOf("\\[", from), open: "\\[", close: "\\]" },
      { start: input.indexOf("\\(", from), open: "\\(", close: "\\)" },
    ].filter((candidate) => candidate.start >= 0);

    let dollarStart = input.indexOf("$", from);
    while (dollarStart >= 0) {
      const previous = dollarStart > 0 ? input[dollarStart - 1] : "";
      const next = dollarStart + 1 < input.length ? input[dollarStart + 1] : "";
      if (previous !== "\\" && next !== "$") {
        candidates.push({ start: dollarStart, open: "$", close: "$" });
        break;
      }
      dollarStart = input.indexOf("$", dollarStart + 1);
    }

    return candidates.sort((left, right) => left.start - right.start)[0];
  };

  while (index < input.length) {
    const candidate = nextCandidate(index);
    if (!candidate) {
      output.push(input.slice(index));
      break;
    }

    const bodyStart = candidate.start + candidate.open.length;
    const isInline = candidate.close === "$";
    const closeStart = isInline
      ? (isWhitespace(input[bodyStart]) ? -1 : findClosingDollar(bodyStart))
      : input.indexOf(candidate.close, bodyStart);
    if (closeStart < 0 && isInline) {
      output.push(input.slice(index, bodyStart));
      index = bodyStart;
      continue;
    }
    if (closeStart < 0) {
      output.push(input.slice(index));
      break;
    }

    output.push(input.slice(index, candidate.start));
    output.push(`${MATH_TOKEN_PREFIX}${segments.length}@@`);
    segments.push(input.slice(candidate.start, closeStart + candidate.close.length));
    index = closeStart + candidate.close.length;
  }

  return { markdown: output.join(""), segments };
}

/// Puts the lifted math spans back into the rendered HTML. `replacement` is
/// called with the exact source and its index; it must not return anything
/// containing a dollar sign, because `replaceAll` reads `$$` in a string
/// replacement as an escape. The renderer returns an empty placeholder element
/// and typesets from `segments` afterwards, which sidesteps that entirely; an
/// earlier version substituted the math source itself and every `$$…$$` display
/// block came back as `$…$`, so display equations rendered inline.
export function restoreMath(html, segments, replacement) {
  return segments.reduce(
    (result, segment, index) => result.replaceAll(`${MATH_TOKEN_PREFIX}${index}@@`, replacement(segment, index)),
    html,
  );
}

const FOLLOW_UPS_OPEN = "<flm_follow_ups>";
const FOLLOW_UPS_CLOSE = "</flm_follow_ups>";
const FOLLOW_UPS_LIMIT = 3;
const FOLLOW_UP_MAX_LENGTH = 160;
// The same patterns as `ChatFollowUps` in the app. A label a model writes over
// the block ("Suggested questions:", "**Follow-up questions**"); a code fence
// line, and a closing one; the sample lines of the block's first template.
const FOLLOW_UPS_LABEL = /^\s*(?:#{1,6}\s*)?(?:\*\*|__|\*|_)?\s*(?:suggested\s+(?:follow[- ]?up\s+)?|follow[- ]?up\s+)questions?\s*:?\s*(?:\*\*|__|\*|_)?\s*:?\s*$/i;
const FENCE_LINE = /^\s*(?:`{3,}|~{3,})[\w-]*\s*$/;
const FENCE_CLOSING_LINE = /^\s*(?:`{3,}|~{3,})\s*$/;
const FOLLOW_UP_PLACEHOLDER = /^(?:first|second|third) question\??$/i;
// Nothing after a block but blanks and the start of a closing fence.
const FENCE_STILL_ARRIVING = /^[\s`~]*$/;

/// One line of a follow-up block as the question it names, or null for a line
/// that is not one: a list marker and wrapping quotes come off, and a link, a
/// tag, an overlong line or the block's dressing (a label, a fence, a
/// template's sample line) is refused.
function followUpQuestion(line) {
  const question = line
    .trim()
    .replace(/^(?:[-*•]|\d+[.)])\s+/, "")
    .replace(/^["“”'‘’](.*)["“”'‘’]$/s, "$1")
    .replace(/\s+/g, " ")
    .trim();
  if (!question || question.includes("](") || question.includes("<")) return null;
  if (FOLLOW_UPS_LABEL.test(question) || FENCE_LINE.test(question) || FOLLOW_UP_PLACEHOLDER.test(question)) return null;
  return question.length > FOLLOW_UP_MAX_LENGTH ? null : question;
}

/// `text` up to its last line that is not blank, when `matches` accepts that
/// line; null when it does not.
function droppingLastLine(text, matches) {
  const end = text.trimEnd().length;
  if (end === 0) return null;
  const start = text.lastIndexOf("\n", end - 1) + 1;
  return matches(text.slice(start, end)) ? text.slice(0, start) : null;
}

/// `text` after its first line that is not blank, when `matches` accepts that
/// line; null when it does not.
function droppingFirstLine(text, matches) {
  const start = text.length - text.trimStart().length;
  if (start === text.length) return null;
  const newline = text.indexOf("\n", start);
  const end = newline < 0 ? text.length : newline;
  return matches(text.slice(start, end)) ? text.slice(end) : null;
}

const isLabelLine = (line) => FOLLOW_UPS_LABEL.test(line);
const isFenceLine = (line) => FENCE_LINE.test(line);
const isFenceClosing = (line) => FENCE_CLOSING_LINE.test(line);

/// `text` without its last line when that line opens a code fence: a fence
/// line after an even number of them. The fence that closes a code block the
/// reply really wrote stays.
function droppingOpeningFence(text) {
  const unfenced = droppingLastLine(text, isFenceLine);
  if (unfenced === null) return null;
  const fencesBefore = unfenced.split("\n").filter(isFenceLine).length;
  return fencesBefore % 2 === 0 ? unfenced : null;
}

/// What comes before a block still streaming in, without the label line over
/// it or a fence opened for it, which would draw as an empty code box running
/// to the end.
function strippingLeadIn(before) {
  const unlabelled = droppingLastLine(before, isLabelLine) ?? before;
  const unfenced = droppingOpeningFence(unlabelled);
  if (unfenced === null) return unlabelled;
  return droppingLastLine(unfenced, isLabelLine) ?? unfenced;
}

/// The suggested questions a reply ends with, `<flm_follow_ups>` then one
/// question a line then `</flm_follow_ups>`, taken out of its prose. The app
/// shows them as cards under the answer, so no surface draws the block, and a
/// reply saved before the app learned to strip it still renders clean.
///
/// Every complete block leaves the prose, and the questions are the last
/// one's lines. While a reply streams, an open block with no close yet goes to
/// the end of the text, and so does a trailing fragment of the opening tag, so
/// neither flashes as text before the rest arrives. A label line just over a
/// block, and a code fence opened for it, go with it. Mirrors `ChatFollowUps`
/// in the app, which is tested on the same fixtures.
export function splitFollowUps(markdown) {
  const text = String(markdown ?? "");
  let prose = "";
  let lastBlock = null;
  let index = 0;
  while (index <= text.length) {
    const open = text.indexOf(FOLLOW_UPS_OPEN, index);
    if (open < 0) {
      prose += text.slice(index);
      break;
    }
    const lead = text.slice(index, open);
    const close = text.indexOf(FOLLOW_UPS_CLOSE, open + FOLLOW_UPS_OPEN.length);
    if (close < 0) {
      // Still streaming: whatever follows is the block.
      prose += strippingLeadIn(lead);
      break;
    }
    let before = droppingLastLine(lead, isLabelLine) ?? lead;
    lastBlock = text.slice(open + FOLLOW_UPS_OPEN.length, close);
    index = close + FOLLOW_UPS_CLOSE.length;
    // A fence opened for the block and closed after it would be an empty code
    // box once the block is gone. So would one whose closing has not arrived
    // yet, or never does.
    const unfenced = droppingOpeningFence(before);
    const after = text.slice(index);
    const unclosed = unfenced === null
      ? null
      : (droppingFirstLine(after, isFenceClosing) ?? (FENCE_STILL_ARRIVING.test(after) ? "" : null));
    if (unclosed !== null) {
      before = droppingLastLine(unfenced, isLabelLine) ?? unfenced;
      index = text.length - unclosed.length;
    }
    prose += before;
  }

  const fragmentStart = prose.lastIndexOf("<");
  if (fragmentStart >= 0) {
    const fragment = prose.slice(fragmentStart);
    if (fragment.length >= 2 && fragment.length < FOLLOW_UPS_OPEN.length && FOLLOW_UPS_OPEN.startsWith(fragment)) {
      prose = strippingLeadIn(prose.slice(0, fragmentStart));
    }
  }

  const questions = [];
  const seen = new Set();
  for (const line of (lastBlock ?? "").split("\n")) {
    const question = followUpQuestion(line);
    if (!question || seen.has(question.toLowerCase())) continue;
    seen.add(question.toLowerCase());
    questions.push(question);
    if (questions.length === FOLLOW_UPS_LIMIT) break;
  }
  return { markdown: prose.trimEnd(), questions };
}

const VISUALIZATION_FENCE = /^[ \t]{0,3}(`{3,}|~{3,})[ \t]*visualization[ \t]*$/i;
const ANY_FENCE = /^[ \t]{0,3}(`{3,}|~{3,})/;

/// A reply cut into its prose and the visualizations it draws. A visualization
/// is a fenced block whose language is `visualization` holding one
/// self-contained HTML document, the same block a page keeps for its Visualize
/// row, so the same Markdown runs in a page too. It is taken out before
/// any Markdown repair, which would otherwise turn its `<br>` and `<p>` into
/// line breaks and lift a template literal's `${…}` out as math.
///
/// Returns parts in reply order: `{ kind: "markdown", text }` and
/// `{ kind: "visualization", html, complete }`. A block whose closing fence has
/// not streamed in yet runs to the end of the text with `complete: false`. A
/// visualization fence inside another code block is that block's text, not a
/// visualization.
export function splitVisualizations(markdown) {
  const lines = String(markdown ?? "").replace(/\r\n?/g, "\n").split("\n");
  const parts = [];
  let prose = [];
  let outerFence = null;
  const closes = (line, fence) => {
    const match = line.match(/^[ \t]{0,3}(`{3,}|~{3,})[ \t]*$/);
    return Boolean(match) && match[1][0] === fence[0] && match[1].length >= fence.length;
  };
  const flushProse = () => {
    if (prose.length > 0) parts.push({ kind: "markdown", text: prose.join("\n") });
    prose = [];
  };

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (outerFence) {
      if (closes(line, outerFence)) outerFence = null;
      prose.push(line);
      continue;
    }
    const opener = line.match(VISUALIZATION_FENCE);
    if (!opener) {
      const fence = line.match(ANY_FENCE);
      if (fence) outerFence = fence[1];
      prose.push(line);
      continue;
    }
    const body = [];
    let closeIndex = -1;
    for (let candidate = index + 1; candidate < lines.length; candidate += 1) {
      if (closes(lines[candidate], opener[1])) {
        closeIndex = candidate;
        break;
      }
      body.push(lines[candidate]);
    }
    flushProse();
    parts.push({ kind: "visualization", html: body.join("\n").trim(), complete: closeIndex >= 0 });
    index = closeIndex >= 0 ? closeIndex : lines.length;
  }
  flushProse();
  return parts;
}

/// The whole text pipeline, in the order the repairs depend on: the follow-up
/// block out first, since it is not part of the reply, then source-link
/// stutter and stray HTML breaks, then math framing, then math is lifted out
/// so the Markdown-shaped repairs cannot reach inside it.
export function normalizeChatMarkdown(markdown) {
  const collapsed = collapseRepeatedSourceTitleLinks(splitFollowUps(markdown).markdown);
  const breaks = normalizeModelLineBreaks(collapsed);
  const latex = normalizeLatexDisplayBlocks(breaks);
  const protectedMath = protectMath(latex);
  const tables = normalizeMarkdownTables(protectedMath.markdown);
  const tasks = normalizeTaskLists(tables);
  return { markdown: normalizeTightMarkdownEmphasis(tasks), segments: protectedMath.segments };
}
