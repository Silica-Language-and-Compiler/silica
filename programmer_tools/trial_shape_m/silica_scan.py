"""Light-weight Silica source scanner used by the item-M trial transformers.

It is not a parser. It masks comments and string literals, then finds the top-level
declarations (`fn NAME(`, `impl X for Supervisor;`, `use m;`) by brace depth, which is
all the transformers need: they move `main` verbatim and add declarations around it.

Masking keeps every byte offset, so spans found on the mask index the original text.
"""

import re

FN_RE = re.compile(r'\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')


def mask(text):
    """Return text with comment and string contents replaced by spaces (same length).

    Newlines are kept so line numbers survive. `//` comments run to end of line.
    Strings are "..." with backslash escapes.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
            for k in range(i + 1, min(j, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 1
        else:
            i += 1
    return ''.join(out)


def string_spans(text):
    """[(start, end)] of every string literal's contents (between the quotes), comments skipped."""
    spans = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
            spans.append((i + 1, min(j, n)))
            i = j + 1
        else:
            i += 1
    return spans


def match_close(m, open_pos, open_ch='{', close_ch='}'):
    """Index of the bracket closing the one at open_pos, on masked text m; -1 if none."""
    depth = 0
    for k in range(open_pos, len(m)):
        ch = m[k]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return k
    return -1


class Fn:
    def __init__(self, name, start, params_open, params_close, body_open, body_close, ret_type):
        self.name = name
        self.start = start            # index of `fn`
        self.params_open = params_open
        self.params_close = params_close
        self.body_open = body_open    # index of the body's `{`
        self.body_close = body_close  # index of the body's `}`
        self.ret_type = ret_type      # text between `->` and the body `{` (stripped), or None

    @property
    def end(self):
        return self.body_close + 1


def depth_map(m):
    """depth[i] = brace depth *before* character i (counting {, ( and [)."""
    d = 0
    out = [0] * (len(m) + 1)
    for i, ch in enumerate(m):
        out[i] = d
        if ch in '{([':
            d += 1
        elif ch in '})]':
            d -= 1
    out[len(m)] = d
    return out


def top_level_fns(text, m=None):
    """All top-level `fn` declarations with bodies."""
    if m is None:
        m = mask(text)
    dm = depth_map(m)
    fns = []
    for mo in FN_RE.finditer(m):
        if dm[mo.start()] != 0:
            continue
        po = mo.end() - 1
        pc = match_close(m, po, '(', ')')
        if pc < 0:
            continue
        # The return type may itself contain braces (record types). The body `{` is the first `{`
        # at depth 0 (relative) after `->` whose preceding type text is balanced. Walk tokens.
        k = pc + 1
        rest = m[k:].lstrip()
        if rest.startswith('{'):
            # no return type (an E1042 error trial): the body follows the parameters
            bo = len(m) - len(rest)
            bc = match_close(m, bo)
            if bc >= 0:
                fns.append(Fn(mo.group(1), mo.start(), po, pc, bo, bc, None))
            continue
        arrow = m.find('->', k)
        semi = m.find(';', k)
        brace = m.find('{', k)
        ret_type = None
        if arrow >= 0 and (brace < 0 or arrow < brace or True):
            # skip the type: balanced brackets until a `{` at depth 0 that follows a complete type.
            j = arrow + 2
            depth = 0
            body_open = -1
            while j < len(m):
                ch = m[j]
                if ch in '([':
                    depth += 1
                elif ch in ')]':
                    depth -= 1
                elif ch == '{':
                    if depth == 0:
                        # a `{` right after `->` (only spaces between) or after `|` / `,` / `:` opens a
                        # record type; otherwise it opens the body.
                        prev = m[arrow + 2:j].strip()
                        if prev == '' or prev.endswith('|') or prev.endswith(':') or prev.endswith(','):
                            depth += 1
                        else:
                            body_open = j
                            break
                    else:
                        depth += 1
                elif ch == '}':
                    depth -= 1
                j += 1
            if body_open < 0:
                continue
            ret_type = text[arrow + 2:body_open].strip()
        else:
            continue
        bc = match_close(m, body_open)
        if bc < 0:
            continue
        fns.append(Fn(mo.group(1), mo.start(), po, pc, body_open, bc, ret_type))
    return fns


SEQ_RE = re.compile(r'^\s*sequence\b')


def body_inner(text, fn):
    return text[fn.body_open + 1:fn.body_close]


def outer_sequence(text, fn, m=None):
    """If fn's body is exactly one `sequence ... produces pure X end` block, return
    (seq_start, produces_pos, pure_expr_start, end_pos) as absolute indexes; else None."""
    if m is None:
        m = mask(text)
    inner_m = m[fn.body_open + 1:fn.body_close]
    if not SEQ_RE.match(inner_m):
        return None
    base = fn.body_open + 1
    seq_start = base + inner_m.index('sequence')
    # find the matching `produces` and `end` at nesting level 0 of sequence/case blocks.
    tok = re.compile(r'\b(sequence|produces|end)\b')
    depth = 0
    produces = None
    end = None
    br = 0
    dm = depth_map(inner_m)
    for mo in tok.finditer(inner_m):
        w = mo.group(1)
        if w == 'sequence':
            depth += 1
        elif w == 'produces':
            if depth == 1 and produces is None:
                produces = base + mo.start()
        elif w == 'end':
            depth -= 1
            if depth == 0:
                end = base + mo.start()
                break
    if produces is None or end is None:
        return None
    if inner_m[end - base + 3:].strip() != '':
        return None
    return (seq_start, produces, end)


IMPL_SUP_RE = re.compile(r'^\s*impl\s+([A-Za-z_][A-Za-z0-9_]*)\s+for\s+Supervisor\s*;', re.M)
USE_RE = re.compile(r'^\s*use\s+([A-Za-z_][A-Za-z0-9_@]*)\s*;', re.M)
