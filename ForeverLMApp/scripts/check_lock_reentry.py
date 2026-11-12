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
import bisect
import os
import re
import sys
from collections import defaultdict

ROOT = os.environ.get('SRCROOT') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ['App', 'Shared', 'MCP', 'iOS', 'iOSShare', 'iOSWidget']
REPORT = '--report' in sys.argv
STAMP_DIR = os.environ.get('DERIVED_FILE_DIR') or os.environ.get('TMPDIR') or '/tmp'
STAMP = os.path.join(STAMP_DIR, 'check_lock_reentry.stamp')

# ---------------------------------------------------------------- sources

files = []
for d in DIRS:
    for dp, dn, fn in os.walk(os.path.join(ROOT, d)):
        dn[:] = [x for x in dn if not x.endswith(('Resources', '.icon'))]
        files += [os.path.join(dp, f) for f in fn if f.endswith('.swift')]
files.sort()

newest = max((os.stat(p).st_mtime for p in files), default=0)
fingerprint = f"{len(files)} {newest} {os.stat(__file__).st_mtime}"
if not REPORT:
    try:
        if open(STAMP).read() == fingerprint:
            sys.exit(0)
    except OSError:
        pass

TOK = re.compile(r'//|/\*|#*"""|#*"')
NESTED_COMMENT = re.compile(r'/\*|\*/')


def blank(seg):
    return '\n'.join(' ' * len(part) for part in seg.split('\n'))


def strip(src):
    """Blank comments and string literals, keeping offsets and newlines."""
    out, i, last, n = [], 0, 0, len(src)
    while True:
        m = TOK.search(src, i)
        if not m:
            break
        t, a = m.group(0), m.start()
        if t == '//':
            e = src.find('\n', a)
            e = n if e < 0 else e
        elif t == '/*':
            depth, k, e = 0, a, n
            while True:
                mm = NESTED_COMMENT.search(src, k)
                if not mm:
                    break
                depth += 1 if mm.group(0) == '/*' else -1
                k = mm.end()
                if depth == 0:
                    e = k
                    break
        else:
            hashes = t[:len(t) - len(t.lstrip('#'))]
            q = t[len(hashes):]
            close = q + hashes
            k = m.end()
            while k < n:
                c = src[k]
                if c == '\\' and not hashes:
                    if src.startswith('\\(', k):  # interpolation: skip to its closing paren
                        d, j = 0, k + 1
                        while j < n:
                            if src[j] == '(':
                                d += 1
                            elif src[j] == ')':
                                d -= 1
                                if d == 0:
                                    break
                            elif src[j] == '"':
                                j2 = src.find('"', j + 1)
                                j = j2 if j2 > 0 else j
                            j += 1
                        k = j + 1
                        continue
                    k += 2
                    continue
                if src.startswith(close, k):
                    k += len(close)
                    break
                if q == '"' and c == '\n':
                    break
                k += 1
            e = k
        out.append(src[last:a])
        out.append(blank(src[a:e]))
        last = i = e
        if i >= n:
            break
    out.append(src[last:])
    return ''.join(out)


LOCK_DECL = re.compile(r'\b(?:let|var)\s+(\w+)\s*(?::\s*[\w<>.,\s\[\]]+)?=\s*(AppLock|NSLock|NSRecursiveLock|OSAllocatedUnfairLock|Mutex|NSCondition)\b')
NSLOCK_CTOR = re.compile(r'\bNSLock\s*\(\s*\)')
DECL = re.compile(r'\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>{]*>)?\s*\(|\bvar\s+([A-Za-z_]\w*)\s*:\s*[^={\n]+\{|\b(init)[?!]?\s*\(|\bsubscript\s*\(')
SIGNATURE_BREAK = re.compile(r'\n\s*(?:func|var|let|case|static|private|public|internal|fileprivate|@|\}|init|subscript|associatedtype|typealias|mutating|nonisolated|override|final|class)\b')
DEFERRED = re.compile(r'\bTask(?:\.detached)?\s*(?:\([^)]*\))?\s*\{|\.async(?:After)?\s*(?:\([^)]*\))?\s*\{|scheduledTimer\([^{]*\{|\.addOperation\s*\{')
LOCALS = re.compile(r'\b_\s+([a-z_]\w*)\s*:|[(,]\s*[a-z_]\w*\s+([a-z_]\w*)\s*:|\b(?:let|var)\s+([a-z_]\w*)|\bfor\s+(?:case\s+let\s+)?\(?([a-z_]\w*)|[{,(]\s*([a-z_]\w*)\s*(?:,\s*([a-z_]\w*)\s*)?\)?\s+in\b')
PARAM = re.compile(r'[(,]\s*([a-z_]\w*)\s*:\s*(?:inout\s+)?[@A-Z(\[]')
SLOW = re.compile(r'\b(Preferences\.(?:set|reset|value)\b|UserDefaults\b[\w.]*\.(?:set|removeObject|synchronize)\b|DispatchQueue\.main\.sync|\.wait\(|URLSession\b|Data\(contentsOf|String\(contentsOf|\.write\(to:|FileManager\.default\.\w+|NotificationCenter\.default\.post|sqlite3_\w+|evaluateJavaScript|MainActor\.assumeIsolated|Thread\.sleep|usleep|\bawait\b)')

raw, texts, braces, newlines = {}, {}, {}, {}
lock_decl, lock_files = {}, defaultdict(set)
for p in files:
    src = open(p, encoding='utf-8', errors='replace').read()
    raw[p] = src.split('\n')
    s = strip(src)
    texts[p] = s
    stack, pairs = [], {}
    for m in re.finditer(r'[{}]', s):
        if m.group(0) == '{':
            stack.append(m.start())
        elif stack:
            pairs[stack.pop()] = m.start()
    braces[p] = pairs
    newlines[p] = [m.start() for m in re.finditer('\n', s)]
    for m in LOCK_DECL.finditer(s):
        lock_decl[(p, m.group(1))] = m.group(2)
        lock_files[m.group(1)].add(p)


def line_of(p, idx):
    return bisect.bisect_left(newlines[p], idx) + 1


def lock_key(p, name):
    if (p, name) in lock_decl:
        return (p, name)
    owners = lock_files.get(name)
    if owners and len(owners) == 1:
        return (next(iter(owners)), name)
    return None


def scope_end(s, a, hi):
    d = 0
    for bm in re.finditer(r'[{}]', s[a:hi]):
        if bm.group(0) == '{':
            d += 1
        else:
            if d == 0:
                return a + bm.start()
            d -= 1
    return hi


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


# ---------------------------------------------------------------- declarations

funcs = []
for p in files:
    s, pairs = texts[p], braces[p]
    for m in DECL.finditer(s):
        name = m.group(1) or m.group(2) or m.group(3) or 'subscript'
        kind = 'var' if m.group(2) else 'func'
        k = m.end()
        if m.group(2) is None:
            d = 1
            while k < len(s) and d:
                if s[k] == '(':
                    d += 1
                elif s[k] == ')':
                    d -= 1
                k += 1
            b = s.find('{', k)
            if b < 0:
                continue
            between = s[k:b]
            if SIGNATURE_BREAK.search(between) or '=' in between.replace('==', ''):
                continue
        else:
            b = m.end() - 1
        e = pairs.get(b)
        if e is None:
            continue
        funcs.append(dict(name=name, kind=kind, file=p, decl=m.start(), start=b, end=e, line=line_of(p, m.start())))

by_name = defaultdict(list)
for i, f in enumerate(funcs):
    by_name[f['name']].append(i)


def resolve(name, p, called):
    cands = [i for i in by_name.get(name, ()) if called or funcs[i]['kind'] == 'var']
    same = [i for i in cands if funcs[i]['file'] == p]
    if same:
        return same
    return cands if 0 < len(cands) <= 2 else []


def locals_in(p, decl, a, e):
    s = texts[p]
    found = set()
    for m in LOCALS.finditer(s, decl, e):
        found.update(g for g in m.groups() if g)
    for m in PARAM.finditer(s, decl, s.find('{', decl)):
        found.add(m.group(1))
    return found


def deferred_spans(p, a, e):
    s, spans = texts[p], []
    for dm in DEFERRED.finditer(s, a, e):
        b = s.find('{', dm.end() - 1)
        if 0 <= b < e:
            spans.append((b, braces[p].get(b, b)))
    return spans


IDENT = re.compile(r'(?<![\w$])([a-z_]\w*)\b')
OWN_QUALIFIER = re.compile(r'\b(self|Self|[A-Z]\w*)\s*$')


def references(p, a, e, decl):
    """Our own functions and computed properties that s[a:e] calls or reads,
    as (name, called) pairs."""
    s = texts[p]
    hits = [m for m in IDENT.finditer(s, a, e) if m.group(1) in by_name]
    if not hits:
        return set()
    skip = deferred_spans(p, a, e)
    local = None
    out = set()
    for m in hits:
        if skip and any(x <= m.start() <= y for x, y in skip):
            continue
        k = m.start() - 1
        while k >= 0 and s[k] in ' \t\n':
            k -= 1
        on_self = False
        if k >= 0 and s[k] == '.':
            q = OWN_QUALIFIER.search(s, max(0, k - 40), k)
            if not q:
                continue  # a member of some other value
            on_self = q.group(1) in ('self', 'Self')
        tail = s[m.end():m.end() + 3].lstrip()
        called = tail.startswith('(')
        if not called and tail.startswith(':') and not tail.startswith('::'):
            continue  # an argument label or a declaration
        if not called and not on_self:
            if local is None:
                local = locals_in(p, decl, a, e)
            if m.group(1) in local:
                continue
        out.add((m.group(1), called))
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
    return 'lock-check: allow' in raw[p][ln - 1] if 0 < ln <= len(raw[p]) else False


def rel(p):
    return os.path.relpath(p, ROOT)


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
try:
    os.makedirs(STAMP_DIR, exist_ok=True)
    open(STAMP, 'w').write(fingerprint)
except OSError:
    pass
