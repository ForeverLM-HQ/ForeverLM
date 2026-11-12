#!/usr/bin/env python3
"""Fail the build on main-thread code that can wait.

The main thread draws the app and takes every click. When it waits on
something (a semaphore, a process, another thread, launchd), the app stops
answering and macOS shows the beachball until the wait ends, or forever. Build
291 hung for good that way inside Sparkle's installer launch (SMJobRemove
waiting on launchd, 2026-11-11). Product rule (product owner, 2026-11-11):
"It has to be impossible for a beach ball to occur."

This scans the app's Swift sources and reports, as Xcode errors, a blocking
call in code that runs on the main thread:

  - the bodies of `@MainActor` types and functions, SwiftUI views, scenes,
    view modifiers and representables, AppKit and UIKit views, windows,
    controllers and app delegates, our subclasses of those, and every
    extension of them (a `nonisolated` member is not main);
  - `DispatchQueue.main.async`, `MainActor.run`, `Task { @MainActor … }` and
    main-queue notification closures anywhere, and a `Task { }` started from
    main code (it inherits the main actor).

A blocking call is one that waits for something else: `DispatchQueue.main.sync`,
`.wait()` on a semaphore, group or condition, `waitUntilExit()`,
`waitUntilAllOperationsAreFinished()`, `Thread.sleep`, `sleep`/`usleep`,
`synchronousRemoteObjectProxyWithErrorHandler`, `NSAppleScript`'s
`executeAndReturnError`, `SMJobRemove`/`SMJobSubmit`/`SMJobBless`, and a
synchronous read of a web URL (`Data(contentsOf: URL(string: …))`). It is also
a call to one of our own synchronous functions or computed properties that
makes such a call, followed through as many functions as it takes (calls are
resolved by name as `swift_scan.py` says; `Task.detached`, other queues and
`Thread`s run elsewhere and are not followed).

Move the wait off the main thread (`Task.detached`, an actor, a background
queue, an async API) rather than waiving it. When a call can only ever return
at once, put `// main-thread-check: allow <why>` on the line named and say why.

  python3 scripts/check_main_thread_blocking.py           check (a build phase runs this)
  python3 scripts/check_main_thread_blocking.py --report  also list slower main-thread work
                                                          (file reads, SQLite, PDF loads),
                                                          which is not an error

It reads the code, it does not run it, so it can miss a wait and can name one
that is not there. Runs in a few seconds; skipped when no Swift file changed.
"""
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_scan import SwiftTree, Stamp, default_root, swift_files  # noqa: E402

ROOT = default_root(__file__)
REPORT = '--report' in sys.argv
WAIVER = 'main-thread-check: allow'

files = swift_files(ROOT)
stamp = Stamp('check_main_thread_blocking', files, __file__)
if not REPORT and stamp.fresh():
    sys.exit(0)

tree = SwiftTree(ROOT, files)
texts, braces, funcs = tree.texts, tree.braces, tree.funcs

BLOCKING = re.compile(
    r'DispatchQueue\s*\.\s*main\s*\.\s*sync\b'
    r'|\.\s*wait\s*\(\s*(?:\)|timeout\s*:|wallTimeout\s*:)'
    r'|\bwaitUntilExit\s*\(\s*\)'
    r'|\bwaitUntilAllOperationsAreFinished\s*\(\s*\)'
    r'|\.\s*waitUntilFinished\s*\(\s*\)'
    r'|\bThread\s*\.\s*sleep\s*\('
    r'|(?<![\w.])(?:u|nano)?sleep\s*\('
    r'|\bsynchronousRemoteObjectProxyWithErrorHandler\b'
    r'|\.\s*executeAndReturnError\s*\('
    r'|\bSMJob(?:Remove|Submit|Bless)\s*\('
    r'|\b(?:NS)?(?:Data|String|Image)\s*\(\s*contentsOf\s*:\s*URL\s*\(\s*string\s*:'
)
SLOW = re.compile(
    r'\b(?:NS)?(?:Data|String)\s*\(\s*contentsOf\s*:'
    r'|\bNSImage\s*\(\s*contentsOf\s*:'
    r'|\bPDFDocument\s*\(\s*url\s*:'
    r'|\bsqlite3_(?:step|exec|prepare_v2)\s*\('
    r'|\.\s*write\s*\(\s*to\s*:'
    r'|FileManager\s*\.\s*default\s*\.\s*(?:contentsOfDirectory|copyItem|moveItem|removeItem|enumerator)\b'
)

# ---------------------------------------------------------------- which types run on the main thread

MAIN_SUPERTYPES = {
    # SwiftUI
    'View', 'App', 'Scene', 'Commands', 'ViewModifier', 'ToolbarContent', 'DropDelegate',
    'ButtonStyle', 'PrimitiveButtonStyle', 'ToggleStyle', 'LabelStyle', 'MenuStyle',
    'NSViewRepresentable', 'NSViewControllerRepresentable',
    'UIViewRepresentable', 'UIViewControllerRepresentable',
    # AppKit
    'NSResponder', 'NSView', 'NSViewController', 'NSWindowController', 'NSWindow', 'NSPanel',
    'NSApplication', 'NSApplicationDelegate', 'NSWindowDelegate', 'NSControl', 'NSButton',
    'NSTextField', 'NSSearchField', 'NSTextView', 'NSScrollView', 'NSClipView', 'NSTableView',
    'NSOutlineView', 'NSTableCellView', 'NSTableRowView', 'NSCollectionView', 'NSCollectionViewItem',
    'NSMenu', 'NSMenuItem', 'NSHostingView', 'NSHostingController', 'NSVisualEffectView',
    'NSImageView', 'NSStackView', 'NSSplitView', 'NSSplitViewController', 'NSTabView',
    'WKWebView', 'PDFView', 'PDFThumbnailView',
    # UIKit
    'UIResponder', 'UIView', 'UIViewController', 'UIWindow', 'UIApplicationDelegate',
    'UIWindowSceneDelegate', 'UIHostingController', 'UITextView', 'UIScrollView',
}

TYPE_DECL = re.compile(
    r'((?:@[\w.]+(?:\([^)]*\))?\s+|(?:public|private|fileprivate|internal|open|final|indirect|nonisolated)\s+)*)'
    r'\b(class|struct|enum|actor|extension|protocol)\s+([A-Za-z_][\w.]*)\s*(?:<[^>{]*>)?([^{]*)\{'
)

types = []          # (file, kind, name, attrs, supertypes, open brace, close brace)
for p in files:
    s = texts[p]
    for m in TYPE_DECL.finditer(s):
        kind, name = m.group(2), m.group(3).split('.')[-1]
        if kind == 'class' and re.match(r'\s*(?:func|var|let|subscript)\b', s[m.end(3):m.end(3) + 12]):
            continue  # `class func`, `class var`
        head = m.group(4)
        head = re.split(r'\bwhere\b', head)[0]
        supers = set()
        if ':' in head:
            for item in head.split(':', 1)[1].split(','):
                item = re.sub(r'<.*', '', item).strip().split('.')[-1]
                if item:
                    supers.add(item)
        b = m.end() - 1
        e = braces[p].get(b)
        if e is None:
            continue
        attrs = m.group(1) or ''
        # attributes on the lines above (`@Observable @MainActor` then `class X {`)
        before = s[max(0, m.start() - 200):m.start()]
        lead = re.search(r'((?:@[\w.]+(?:\([^)]*\))?\s*)+)$', before)
        if lead:
            attrs = lead.group(1) + ' ' + attrs
        types.append(dict(file=p, kind=kind, name=name, attrs=attrs, supers=supers, start=b, end=e))

main_names = set()
for t in types:
    if t['kind'] in ('actor', 'protocol') or 'nonisolated' in t['attrs']:
        continue
    if '@MainActor' in t['attrs'] or t['supers'] & MAIN_SUPERTYPES:
        main_names.add(t['name'])
changed = True
while changed:
    changed = False
    for t in types:
        if t['kind'] in ('class', 'struct', 'enum', 'extension') and t['name'] not in main_names \
                and '@MainActor' not in t['attrs'] and t['supers'] & main_names and 'nonisolated' not in t['attrs']:
            if t['kind'] != 'extension':
                main_names.add(t['name'])
                changed = True
not_main_names = {t['name'] for t in types if t['kind'] == 'actor'}

type_blocks = defaultdict(list)
for t in types:
    is_main = (t['name'] in main_names and t['name'] not in not_main_names and t['kind'] != 'protocol'
               and 'nonisolated' not in t['attrs'])
    if t['kind'] == 'extension' and t['supers'] & MAIN_SUPERTYPES and t['name'] not in not_main_names:
        is_main = True  # `extension Foo: View`
    if '@MainActor' in t['attrs']:
        is_main = True
    type_blocks[t['file']].append((t['start'], t['end'], is_main))


def innermost_type(p, idx):
    best = None
    for a, e, is_main in type_blocks[p]:
        if a < idx < e and (best is None or a > best[0]):
            best = (a, e, is_main)
    return best


def decl_attributes(p, f):
    """The attributes and modifiers written before a declaration."""
    s = texts[p]
    k = f['decl']
    lo = max(0, k - 300)
    head = s[lo:k]
    cut = max(head.rfind('}'), head.rfind('{'), head.rfind(';'))
    return head[cut + 1:]


for f in funcs:
    attrs = decl_attributes(f['file'], f)
    if re.search(r'\bnonisolated\b', attrs):
        f['main'] = False
    elif '@MainActor' in attrs:
        f['main'] = True
    else:
        t = innermost_type(f['file'], f['decl'])
        f['main'] = bool(t and t[2])

# ---------------------------------------------------------------- closures that run elsewhere, or on main

OFF_MAIN = re.compile(
    r'\bTask\s*\.\s*detached\s*(?:\([^)]*\))?\s*\{'
    r'|DispatchQueue\s*\.\s*global\s*\([^)]*\)\s*\.\s*async(?:After)?\s*(?:\([^)]*\))?\s*\{'
    r'|\b(?!main\b)[a-z]\w*(?:Queue|queue)\s*\.\s*(?:async(?:After)?|sync)\s*(?:\([^)]*\))?\s*\{'
    r'|\bThread\s*(?:\(\s*block\s*:\s*)?\{'
    r'|\.\s*addOperation\s*\{'
    r'|\bTask\s*(?:\([^)]*\))?\s*\{\s*(?:\[[^\]]*\]\s*)?(?:@concurrent|nonisolated)\b'
)
ON_MAIN = re.compile(
    r'DispatchQueue\s*\.\s*main\s*\.\s*async(?:After)?\s*(?:\([^)]*\))?\s*\{'
    r'|\bMainActor\s*\.\s*run\s*(?:\([^)]*\))?\s*\{'
    r'|\bTask\s*(?:\([^)]*\))?\s*\{\s*@MainActor\b'
    r'|queue\s*:\s*(?:\.main|OperationQueue\s*\.\s*main)\s*(?:,\s*using\s*:\s*)?\)?\s*\{'
    r'|RunLoop\s*\.\s*main\s*\.\s*perform\s*(?:\([^)]*\))?\s*\{'
)
LATER = re.compile(r'\bTask\s*(?:\([^)]*\))?\s*\{|\.\s*async(?:After)?\s*(?:\([^)]*\))?\s*\{|scheduledTimer\([^{]*\{|\.\s*addOperation\s*\{')


def file_spans(p, pattern):
    s, out = texts[p], []
    for m in pattern.finditer(s):
        b = s.find('{', m.start())
        if 0 <= b < m.end() + 1:
            out.append((b, braces[p].get(b, b)))
    return out


def within(sp, a, e):
    return [x for x in sp if a <= x[0] < e]


def inside(x, sp):
    return any(a <= x <= b for a, b in sp)


off_spans = {p: file_spans(p, OFF_MAIN) for p in files}
later_spans = {p: file_spans(p, LATER) for p in files}
on_main_spans = {p: file_spans(p, ON_MAIN) for p in files}
blocking_hits = {p: [m for m in BLOCKING.finditer(texts[p])] for p in files}

funcs_in = defaultdict(list)
for i, f in enumerate(funcs):
    funcs_in[f['file']].append(i)


def main_spans(p):
    """Spans of file p whose code runs on the main thread: (start, end, function index or None)."""
    out = [(funcs[i]['start'], funcs[i]['end'], i) for i in funcs_in[p] if funcs[i]['main']]
    out += [(a, b, None) for a, b in on_main_spans[p]]
    return out


def name_pattern(names):
    return re.compile(r'(?<![\w$])(' + '|'.join(sorted(map(re.escape, names))) + r')\b')


# ---------------------------------------------------------------- which synchronous functions wait

blocks, why = {}, {}
for i, f in enumerate(funcs):
    if f['is_async']:
        continue
    p = f['file']
    skip = within(later_spans[p], f['start'], f['end']) + within(off_spans[p], f['start'], f['end'])
    for m in blocking_hits[p]:
        if f['start'] <= m.start() <= f['end'] and not inside(m.start(), skip):
            ln = tree.line_of(p, m.start())
            if not tree.waived(p, ln, WAIVER):
                blocks[i] = True
                why[i] = ('direct', m.group(0).strip(), ln)
                break

frontier = set(blocks)
while frontier:
    pattern = name_pattern({funcs[j]['name'] for j in frontier})
    found = set()
    for i, f in enumerate(funcs):
        if i in blocks or f['is_async']:
            continue
        p, s = f['file'], texts[f['file']]
        if not pattern.search(s, f['start'], f['end'] + 1):
            continue
        skip = within(later_spans[p], f['start'], f['end']) + within(off_spans[p], f['start'], f['end'])
        for name, called, pos in sorted(tree.references(p, f['start'], f['end'] + 1, f['decl'],
                                                        with_positions=True, skip=skip), key=lambda r: r[2]):
            if tree.waived(p, tree.line_of(p, pos), WAIVER):
                continue
            hit = next((j for j in tree.resolve(name, p, called)
                        if j != i and j in blocks and not funcs[j]['is_async']), None)
            if hit is not None:
                blocks[i], why[i] = True, ('via', hit, tree.line_of(p, pos))
                found.add(i)
                break
    frontier = found


def chain(j, depth=0):
    f = funcs[j]
    here = f"{f['name']} ({os.path.basename(f['file'])}:{f['line']})"
    w = why.get(j)
    if w is None or depth > 8:
        return [here]
    if w[0] == 'direct':
        return [here, f"{w[1]} at line {w[2]}"]
    return [here] + chain(w[1], depth + 1)


# ---------------------------------------------------------------- findings

errors, slow = set(), set()
waiting = name_pattern({funcs[j]['name'] for j in blocks}) if blocks else None
for p in files:
    s = texts[p]
    for a, e, owner in main_spans(p):
        skip = within(off_spans[p], a, e) + [
            (funcs[k]['start'], funcs[k]['end']) for k in funcs_in[p]
            if a < funcs[k]['start'] and funcs[k]['end'] <= e and not funcs[k]['main'] and k != owner]
        for m in blocking_hits[p]:
            if a <= m.start() <= e and not inside(m.start(), skip):
                ln = tree.line_of(p, m.start())
                if not tree.waived(p, ln, WAIVER):
                    errors.add(f"{p}:{ln}: error: {m.group(0).strip()} on the main thread; it waits, and the app "
                               f"beachballs until it returns. Run it off the main thread (scripts/check_main_thread_blocking.py)")
        if waiting and waiting.search(s, a, e + 1):
            decl = funcs[owner]['decl'] if owner is not None else a
            for name, called, pos in tree.references(p, a, e + 1, decl, with_positions=True, skip=skip):
                ln = tree.line_of(p, pos)
                if tree.waived(p, ln, WAIVER):
                    continue
                for j in tree.resolve(name, p, called):
                    if j == owner or j not in blocks or funcs[j]['is_async'] or funcs[j]['start'] <= pos <= funcs[j]['end']:
                        continue
                    errors.add(f"{p}:{ln}: error: the main thread waits here, through {' -> '.join(chain(j))}; the app "
                               f"beachballs until it returns. Run it off the main thread (scripts/check_main_thread_blocking.py)")
                    break
        if REPORT:
            for m in SLOW.finditer(s, a, e + 1):
                if not inside(m.start(), skip):
                    slow.add(f"{tree.rel(p)}:{tree.line_of(p, m.start())}  {m.group(0).strip()}")

for x in sorted(errors):
    print(x)
if REPORT:
    print(f"\n{len(files)} files, {len(main_names)} main-thread types, "
          f"{sum(1 for f in funcs if f['main'])} main-thread functions, {len(blocks)} synchronous functions that wait")
    for j in sorted(blocks, key=lambda j: (funcs[j]['file'], funcs[j]['line'])):
        print(f"  waits: {' -> '.join(chain(j))}")
    print("Slower work on the main thread (not an error):")
    for x in sorted(slow):
        print("  " + x)
if errors:
    sys.exit(1)
stamp.write()
