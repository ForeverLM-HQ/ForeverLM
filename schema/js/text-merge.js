// A line-level three-way merge for a Doc body (docs/cloudkit-schema-design.md §6.2 step 4, §15.1
// R12): the twin of the Mac's ArtifactThreeWayMerge.swift, so the web and the hosted MCP settle a
// body both sides changed exactly as a Mac does. Changes to different lines merge on their own, and
// the same or adjacent lines changed on both sides are a conflict the writer settles. A conflict
// never produces marked-up text; the caller keeps one whole version and holds the other.
//
// Two of Swift's String rules carry over. Lines are split on the character "\n", and "\r\n" is one
// character in Swift, so a CRLF body is a single line. Lines and texts compare by canonical
// equivalence (NFC), as Swift strings do, while the merged text keeps each line as one side wrote
// it. Vectors: schema/vectors/text-merge.json.

/** Past this many cells of the line-diff table a merge is not attempted: the change is a conflict. */
export const MAX_DIFF_CELLS = 4_000_000;

/**
 * `{merged: text}`, or `{conflict: true}` when both sides changed the same or adjacent lines (or the
 * changed region is too large to diff).
 * @param {string} base
 * @param {string} mine
 * @param {string} theirs
 * @returns {{merged: string} | {conflict: true}}
 */
export function threeWayMerge(base, mine, theirs) {
  if (same(mine, theirs)) return { merged: mine };
  if (same(base, mine)) return { merged: theirs };
  if (same(base, theirs)) return { merged: mine };

  const baseLines = lines(base);
  const mineHunks = hunks(baseLines, lines(mine));
  const theirHunks = hunks(baseLines, lines(theirs));
  if (!mineHunks || !theirHunks) return { conflict: true };

  /** @type {string[]} */
  const out = [];
  let cursor = 0;
  /** @param {Hunk} hunk */
  const take = (hunk) => {
    out.push(...baseLines.slice(cursor, hunk.baseStart), ...hunk.replacement);
    cursor = hunk.baseEnd;
  };
  let i = 0;
  let j = 0;
  while (i < mineHunks.length || j < theirHunks.length) {
    if (i < mineHunks.length && j < theirHunks.length) {
      const a = mineHunks[i];
      const b = theirHunks[j];
      if (a.baseStart <= b.baseEnd && b.baseStart <= a.baseEnd) {
        // The same change made on both sides is one change.
        if (!sameHunk(a, b)) return { conflict: true };
        take(a);
        i += 1;
        j += 1;
      } else if (a.baseStart <= b.baseStart) {
        take(a);
        i += 1;
      } else {
        take(b);
        j += 1;
      }
    } else if (i < mineHunks.length) {
      take(mineHunks[i]);
      i += 1;
    } else {
      take(theirHunks[j]);
      j += 1;
    }
  }
  out.push(...baseLines.slice(cursor));
  return { merged: out.join("\n") };
}

/**
 * The lines of a text: split on "\n" with empty pieces kept, except where "\n" follows "\r" (Swift
 * reads "\r\n" as one character).
 * @param {string} text
 */
export function lines(text) {
  return text.split(/(?<!\r)\n/);
}

/**
 * @typedef {{baseStart: number, baseEnd: number, replacement: string[]}} Hunk
 * One region of the base replaced by other lines. An insertion has an empty base range at the line
 * it goes before.
 */

/**
 * The changes that turn `base` into `target`, as sorted, non-touching hunks; null when the changed
 * region is too large to diff.
 * @param {string[]} base
 * @param {string[]} target
 * @returns {Hunk[] | null}
 */
export function hunks(base, target) {
  const baseKeys = base.map(key);
  const targetKeys = target.map(key);
  let prefix = 0;
  while (prefix < base.length && prefix < target.length && baseKeys[prefix] === targetKeys[prefix]) prefix += 1;
  let suffix = 0;
  while (suffix < base.length - prefix && suffix < target.length - prefix
    && baseKeys[base.length - 1 - suffix] === targetKeys[target.length - 1 - suffix]) {
    suffix += 1;
  }
  const baseMid = baseKeys.slice(prefix, base.length - suffix);
  const targetMid = target.slice(prefix, target.length - suffix);
  const targetMidKeys = targetKeys.slice(prefix, target.length - suffix);
  if (baseMid.length === 0 && targetMid.length === 0) return [];
  if (baseMid.length === 0) return [{ baseStart: prefix, baseEnd: prefix, replacement: targetMid }];
  if (targetMid.length === 0) return [{ baseStart: prefix, baseEnd: prefix + baseMid.length, replacement: [] }];
  if (baseMid.length * targetMid.length > MAX_DIFF_CELLS) return null;

  // Compare interned line ids rather than strings while filling the table.
  /** @type {Map<string, number>} */
  const ids = new Map();
  /** @param {string} line */
  const intern = (line) => {
    let id = ids.get(line);
    if (id === undefined) {
      id = ids.size;
      ids.set(line, id);
    }
    return id;
  };
  const a = baseMid.map(intern);
  const b = targetMidKeys.map(intern);
  const n = a.length;
  const m = b.length;
  const width = m + 1;
  const table = new Int32Array((n + 1) * width);
  for (let i = 1; i <= n; i += 1) {
    for (let j = 1; j <= m; j += 1) {
      table[i * width + j] = a[i - 1] === b[j - 1]
        ? table[(i - 1) * width + (j - 1)] + 1
        : Math.max(table[(i - 1) * width + j], table[i * width + (j - 1)]);
    }
  }

  /** @type {number[]} -1 equal, -2 delete a base line, else the target line inserted. */
  const ops = [];
  let i = n;
  let j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] === b[j - 1]) {
      ops.push(-1);
      i -= 1;
      j -= 1;
    } else if (j > 0 && (i === 0 || table[i * width + (j - 1)] >= table[(i - 1) * width + j])) {
      ops.push(j - 1);
      j -= 1;
    } else {
      ops.push(-2);
      i -= 1;
    }
  }
  ops.reverse();

  /** @type {Hunk[]} */
  const result = [];
  /** @type {Hunk | null} */
  let open = null;
  let baseIndex = prefix;
  for (const op of ops) {
    if (op === -1) {
      if (open) {
        result.push(open);
        open = null;
      }
      baseIndex += 1;
    } else if (op === -2) {
      if (!open) open = { baseStart: baseIndex, baseEnd: baseIndex, replacement: [] };
      baseIndex += 1;
      open.baseEnd = baseIndex;
    } else {
      if (!open) open = { baseStart: baseIndex, baseEnd: baseIndex, replacement: [] };
      open.replacement.push(targetMid[op]);
    }
  }
  if (open) result.push(open);
  return result;
}

/** A line's identity under canonical equivalence. @param {string} line */
function key(line) {
  return /^[\x00-\x7f]*$/.test(line) ? line : line.normalize("NFC");
}

/** @param {string} a @param {string} b */
function same(a, b) {
  return a === b || key(a) === key(b);
}

/** @param {Hunk} a @param {Hunk} b */
function sameHunk(a, b) {
  return a.baseStart === b.baseStart && a.baseEnd === b.baseEnd && a.replacement.length === b.replacement.length
    && a.replacement.every((line, index) => same(line, b.replacement[index]));
}
