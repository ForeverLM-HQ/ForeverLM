"""Read the app's Swift sources the way the build's safety checks need them.

Shared by `check_lock_reentry.py` and `check_main_thread_blocking.py`. It does
not parse Swift: it blanks comments and string literals (keeping every offset
and newline), pairs braces, finds function, initializer, subscript and
computed-property bodies, and resolves a call by name (the same file first,
else a name declared at most twice in the app). Calls on other values
(`x.f()`) are not followed, and work inside a `Task`, `async` or timer closure
counts as running later.
"""
import bisect
import os
import re
from collections import defaultdict

DIRS = ['App', 'Shared', 'MCP', 'iOS', 'iOSShare', 'iOSWidget']


def default_root(script_file):
    return os.environ.get('SRCROOT') or os.path.dirname(os.path.dirname(os.path.abspath(script_file)))


def swift_files(root, dirs=DIRS):
    files = []
    for d in dirs:
        for dp, dn, fn in os.walk(os.path.join(root, d)):
            dn[:] = [x for x in dn if not x.endswith(('Resources', '.icon'))]
            files += [os.path.join(dp, f) for f in fn if f.endswith('.swift')]
    files.sort()
    return files


class Stamp:
    """Skip a check when no Swift file (and no checker) changed since it last passed."""

    def __init__(self, name, files, *scripts):
        directory = os.environ.get('DERIVED_FILE_DIR') or os.environ.get('TMPDIR') or '/tmp'
        self.directory = directory
        self.path = os.path.join(directory, name + '.stamp')
        newest = max((os.stat(p).st_mtime for p in files), default=0)
        marks = ' '.join(str(os.stat(s).st_mtime) for s in scripts + (__file__,))
        self.fingerprint = f"{len(files)} {newest} {marks}"

    def fresh(self):
        try:
            return open(self.path).read() == self.fingerprint
        except OSError:
            return False

    def write(self):
        try:
            os.makedirs(self.directory, exist_ok=True)
            open(self.path, 'w').write(self.fingerprint)
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


DECL = re.compile(r'\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>{]*>)?\s*\(|\bvar\s+([A-Za-z_]\w*)\s*:\s*[^={\n]+\{|\b(init)[?!]?\s*\(|\bsubscript\s*\(')
SIGNATURE_BREAK = re.compile(r'\n\s*(?:func|var|let|case|static|private|public|internal|fileprivate|@|\}|init|subscript|associatedtype|typealias|mutating|nonisolated|override|final|class)\b')
DEFERRED = re.compile(r'\bTask(?:\.detached)?\s*(?:\([^)]*\))?\s*\{|\.async(?:After)?\s*(?:\([^)]*\))?\s*\{|scheduledTimer\([^{]*\{|\.addOperation\s*\{')
LOCALS = re.compile(r'\b_\s+([a-z_]\w*)\s*:|[(,]\s*[a-z_]\w*\s+([a-z_]\w*)\s*:|\b(?:let|var)\s+([a-z_]\w*)|\bfor\s+(?:case\s+let\s+)?\(?([a-z_]\w*)|[{,(]\s*([a-z_]\w*)\s*(?:,\s*([a-z_]\w*)\s*)?\)?\s+in\b')
PARAM = re.compile(r'[(,]\s*([a-z_]\w*)\s*:\s*(?:inout\s+)?[@A-Z(\[]')
IDENT = re.compile(r'(?<![\w$])([a-z_]\w*)\b')
OWN_QUALIFIER = re.compile(r'\b(self|Self|[A-Z]\w*)\s*$')


class SwiftTree:
    def __init__(self, root, files):
        self.root = root
        self.files = files
        self.raw, self.texts, self.braces, self.newlines = {}, {}, {}, {}
        for p in files:
            src = open(p, encoding='utf-8', errors='replace').read()
            self.raw[p] = src.split('\n')
            s = strip(src)
            self.texts[p] = s
            stack, pairs = [], {}
            for m in re.finditer(r'[{}]', s):
                if m.group(0) == '{':
                    stack.append(m.start())
                elif stack:
                    pairs[stack.pop()] = m.start()
            self.braces[p] = pairs
            self.newlines[p] = [m.start() for m in re.finditer('\n', s)]
        self._declarations()

    # ------------------------------------------------------------ positions

    def line_of(self, p, idx):
        return bisect.bisect_left(self.newlines[p], idx) + 1

    def rel(self, p):
        return os.path.relpath(p, self.root)

    def waived(self, p, ln, marker):
        return marker in self.raw[p][ln - 1] if 0 < ln <= len(self.raw[p]) else False

    @staticmethod
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

    # ------------------------------------------------------------ declarations

    def _declarations(self):
        self.funcs = []
        for p in self.files:
            s, pairs = self.texts[p], self.braces[p]
            for m in DECL.finditer(s):
                name = m.group(1) or m.group(2) or m.group(3) or 'subscript'
                kind = 'var' if m.group(2) else 'func'
                k = m.end()
                signature = ''
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
                    signature = between
                else:
                    b = m.end() - 1
                e = pairs.get(b)
                if e is None:
                    continue
                self.funcs.append(dict(name=name, kind=kind, file=p, decl=m.start(), start=b, end=e,
                                       line=self.line_of(p, m.start()),
                                       is_async=bool(re.search(r'\basync\b', signature))))
        self.by_name = defaultdict(list)
        for i, f in enumerate(self.funcs):
            self.by_name[f['name']].append(i)

    def resolve(self, name, p, called):
        cands = [i for i in self.by_name.get(name, ()) if called or self.funcs[i]['kind'] == 'var']
        same = [i for i in cands if self.funcs[i]['file'] == p]
        if same:
            return same
        return cands if 0 < len(cands) <= 2 else []

    def locals_in(self, p, decl, a, e):
        s = self.texts[p]
        found = set()
        for m in LOCALS.finditer(s, decl, e):
            found.update(g for g in m.groups() if g)
        for m in PARAM.finditer(s, decl, s.find('{', decl)):
            found.add(m.group(1))
        return found

    def deferred_spans(self, p, a, e):
        s, spans = self.texts[p], []
        for dm in DEFERRED.finditer(s, a, e):
            b = s.find('{', dm.end() - 1)
            if 0 <= b < e:
                spans.append((b, self.braces[p].get(b, b)))
        return spans

    def references(self, p, a, e, decl, with_positions=False, skip=None):
        """Our own functions and computed properties that s[a:e] calls or reads,
        as (name, called) pairs, or (name, called, offset) with positions.
        `skip` lists the spans to leave out; by default the closures that run
        later (`deferred_spans`)."""
        s = self.texts[p]
        hits = [m for m in IDENT.finditer(s, a, e) if m.group(1) in self.by_name]
        if not hits:
            return set()
        if skip is None:
            skip = self.deferred_spans(p, a, e)
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
                    local = self.locals_in(p, decl, a, e)
                if m.group(1) in local:
                    continue
            out.add((m.group(1), called, m.start()) if with_positions else (m.group(1), called))
        return out
