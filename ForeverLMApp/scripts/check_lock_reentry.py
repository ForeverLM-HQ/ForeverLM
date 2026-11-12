#!/usr/bin/env python3
"""Fail the build on a lock that can hang the app.

A lock taken again on the thread that already holds it waits on itself
forever; once the main thread wants that lock, the app beachballs until it is
force quit. Build 291 did that when the AI activity list opened: a model
catalog helper took the release-date lock and called a loader that took it
again. Two locks taken in opposite orders on two threads hang the same way.

This scans the app's Swift sources (App, Shared, MCP, iOS, iOSShare,
iOSWidget) and reports, as Xcode errors:

  1. `NSLock()` in app code. Use `AppLock()` (Shared/Utilities/AppLock.swift),
     which goes on instead of hanging when it is re-entered.
  2. A locked region (`x.withLock { … }`, or `x.lock()` up to its unlock or the
     end of the scope) that, directly or through the functions and computed
     properties it calls, takes the same lock again.
  3. A cycle in lock order: lock A held while B is taken in one place, B held
     while A is taken in another.

It reads the code, it does not run it: a call is resolved by name (the same
file first, else a name declared at most twice in the app), calls on other
values (`x.f()`) are not followed, and work inside a `Task`, `async` or timer
closure counts as running later, after the lock is released. So it can miss a
hang, and it can report one that is not there. To waive a report, put
`// lock-check: allow <why>` on the line it names; say in the reason why the
lock cannot be held there.

  python3 scripts/check_lock_reentry.py            check (a build phase runs this)
  python3 scripts/check_lock_reentry.py --report   also list slow work under a lock

Runs in a few seconds; skipped when no Swift file changed since the last pass.
"""
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_scan import SwiftTree, Stamp, default_root, swift_files  # noqa: E402

ROOT = default_root(__file__)
REPORT = '--report' in sys.argv

# ---------------------------------------------------------------- sources

files = swift_files(ROOT)
stamp = Stamp('check_lock_reentry', files, __file__)
if not REPORT and stamp.fresh():
    sys.exit(0)

tree = SwiftTree(ROOT, files)
texts, braces, raw = tree.texts, tree.braces, tree.raw
funcs, by_name = tree.funcs, tree.by_name
line_of, scope_end, resolve = tree.line_of, tree.scope_end, tree.resolve
deferred_spans, references = tree.deferred_spans, tree.references

LOCK_DECL = re.compile(r'\b(?:let|var)\s+(\w+)\s*(?::\s*[\w<>.,\s\[\]]+)?=\s*(AppLock|NSLock|NSRecursiveLock|OSAllocatedUnfairLock|Mutex|NSCondition)\b')
NSLOCK_CTOR = re.compile(r'\bNSLock\s*\(\s*\)')
SLOW = re.compile(r'\b(Preferences\.(?:set|reset|value)\b|UserDefaults\b[\w.]*\.(?:set|removeObject|synchronize)\b|DispatchQueue\.main\.sync|\.wait\(|URLSession\b|Data\(contentsOf|String\(contentsOf|\.write\(to:|FileManager\.default\.\w+|NotificationCenter\.default\.post|sqlite3_\w+|evaluateJavaScript|MainActor\.assumeIsolated|Thread\.sleep|usleep|\bawait\b)')

lock_decl, lock_files = {}, defaultdict(set)
for p in files:
    for m in LOCK_DECL.finditer(texts[p]):
        lock_decl[(p, m.group(1))] = m.group(2)
        lock_files[m.group(1)].add(p)


def lock_key(p, name):
    if (p, name) in lock_decl:
        return (p, name)
    owners = lock_files.get(name)
    if owners and len(owners) == 1:
        return (next(iter(owners)), name)
    return None


def regions(p, lo, hi):
    """Locked regions in [lo, hi): (lock key, start, end)."""
    s, pairs, out = texts[p], braces[p], []
    for m in re.finditer(r'\b(\w+)\s*\.\s*withLock(?:Unchecked)?\s*(\(\s*\{|\{|\()', s[lo:hi]):
        k = lock_key(p, m.group(1))
        if not k:
            continue
        a = lo + m.end() - 1
        if s[a] == '(':
            d, j = 0, a
            while j < len(s):
                if s[j] == '(':
                    d += 1
                elif s[j] == ')':
                    d -= 1
                    if d == 0:
                        break
                j += 1
            out.append((k, a, j))
        else:
            out.append((k, a, pairs.get(a, a)))
    for m in re.finditer(r'\b(\w+)\s*\.\s*lock\(\)', s[lo:hi]):
        k = lock_key(p, m.group(1))
        if not k:
            continue
        a = lo + m.end()
        end = scope_end(s, a, hi)
        name = re.escape(m.group(1))
        if re.compile(r'defer\s*\{\s*(?:[\w.]+\.)?' + name + r'\s*\.\s*unlock\(\)').search(s, a, min(end, a + 300)):
            out.append((k, a, end))
            continue
        um = re.compile(r'\b' + name + r'\s*\.\s*unlock\(\)').search(s, a, end)
        out.append((k, a, um.start() if um else end))
    return out


# ---------------------------------------------------------------- which functions take which locks

direct, fref = [], []
for f in funcs:
    f['regions'] = regions(f['file'], f['start'], f['end'] + 1)
    direct.append({r[0] for r in f['regions']})
    fref.append(references(f['file'], f['start'], f['end'] + 1, f['decl']))

acq = [set(d) for d in direct]
via = [dict() for _ in funcs]
changed, rounds = True, 0
while changed and rounds < 16:
    changed, rounds = False, rounds + 1
    for i, f in enumerate(funcs):
        for name, called in fref[i]:
            for j in resolve(name, f['file'], called):
                if j == i:
                    continue
                for lk in acq[j] - acq[i]:
                    acq[i].add(lk)
                    via[i][lk] = j
                    changed = True


def chain(j, lk, depth=0):
    f = funcs[j]
    out = [f"{f['name']} ({os.path.basename(f['file'])}:{f['line']})"]
    if lk in direct[j] or depth > 8 or lk not in via[j]:
        return out
    return out + chain(via[j][lk], lk, depth + 1)


# ---------------------------------------------------------------- findings

errors, edges, slow, seen = [], defaultdict(set), [], set()


def waived(p, ln):
    return tree.waived(p, ln, 'lock-check: allow')


rel = tree.rel


for p in files:
    for m in NSLOCK_CTOR.finditer(texts[p]):
        ln = line_of(p, m.start())
        if not waived(p, ln):
            errors.append(f"{p}:{ln}: error: NSLock() in app code; use AppLock(), which cannot hang when the thread holding it takes it again (scripts/check_lock_reentry.py)")

for i, f in enumerate(funcs):
    p, s = f['file'], texts[f['file']]
    for (lk, a, e) in f['regions']:
        if (lk, a) in seen:
            continue
        seen.add((lk, a))
        ln = line_of(p, a)
        for (lk2, a2, _) in regions(p, a + 1, e):
            if lk2 == lk:
                if not waived(p, ln):
                    errors.append(f"{p}:{line_of(p, a2)}: error: {lk[1]} is taken again inside its own locked region (line {ln}); a thread waiting on a lock it holds hangs the app")
            else:
                edges[lk].add((lk2, p, line_of(p, a2)))
        for name, called in references(p, a, e + 1, f['decl']):
            for j in resolve(name, p, called):
                if j == i or funcs[j]['start'] <= a <= funcs[j]['end']:
                    continue
                for lk2 in acq[j]:
                    if lk2 == lk:
                        if not waived(p, ln):
                            errors.append(f"{p}:{ln}: error: {lk[1]} is held here and taken again through {' -> '.join(chain(j, lk))}; a thread waiting on a lock it holds hangs the app")
                    else:
                        edges[lk].add((lk2, p, ln))
        if REPORT:
            skip = deferred_spans(p, a, e + 1)
            for m in SLOW.finditer(s, a, e + 1):
                if not any(x <= m.start() <= y for x, y in skip):
                    slow.append(f"{rel(p)}:{line_of(p, m.start())}  [{lk[1]}]  {m.group(0)}")

graph = {k: {v[0] for v in vs} for k, vs in edges.items()}
reported = set()
for start in graph:
    stack = [(start, [start])]
    while stack:
        node, path = stack.pop()
        for nxt in graph.get(node, ()):
            if nxt == start and len(path) > 1:
                cycle = tuple(sorted(path))
                if cycle in reported:
                    continue
                reported.add(cycle)
                where = []
                for a_, b_ in zip(path, path[1:] + [start]):
                    site = sorted(x for x in edges[a_] if x[0] == b_)[0]
                    where.append(f"{a_[1]} then {b_[1]} at {rel(site[1])}:{site[2]}")
                first = sorted(x for x in edges[path[0]] if x[0] == path[1 % len(path)])[0]
                if not waived(first[1], first[2]):
                    errors.append(f"{first[1]}:{first[2]}: error: locks taken in opposite orders ({'; '.join(where)}); two threads can each hold one and wait for the other")
            elif nxt not in path and len(path) < 5:
                stack.append((nxt, path + [nxt]))

for e in sorted(set(errors)):
    print(e)
if REPORT:
    print(f"\n{len(files)} files, {len(lock_decl)} locks, {len(seen)} locked regions")
    print("Slow or blocking work under a lock (not an error):")
    for x in sorted(set(slow)):
        print("  " + x)
if errors:
    sys.exit(1)
stamp.write()
