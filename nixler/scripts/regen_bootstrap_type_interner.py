#!/usr/bin/env python3
"""Regenerate bootstrap-legal src/type_checker/type_interner.silica from Wave C selfhost.

Usage:
  python3 regen_bootstrap_type_interner.py [out_path]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import bootstrap_type_interner as bt  # noqa: E402
import fix_type_interner_bootstrap as fx  # noqa: E402

SELFHOST = SCRIPTS.parent / "src" / "type_checker" / "type_interner.silica"
DEFAULT_OUT = SCRIPTS.parent / "src" / "type_checker" / "type_interner.silica"

GOOD_SCANNERS = {
    "strip_type_spaces_from": '''fn strip_type_spaces_from(s: string, i: int64, acc: string) -> string {
    case i >= len(s) of {
        true -> acc;
        false -> do
            ch: string <- substring(s, i, i + 1);
            next_i: int64 <- i + 1;
            out: string <- case ch == " " of {
                true -> strip_type_spaces_from(s, next_i, acc);
                false -> do
                    new_acc: string <- concat(acc, ch);
                    strip_type_spaces_from(s, next_i, new_acc)
                end
            };
            out
        end
    }
}''',
    "find_matching": '''fn find_matching(s: string, i: int64, open_ch: string, close_ch: string, depth: int64) -> int64 {
    case i >= len(s) of {
        true -> 0 - 1;
        false -> do
            ch: string <- substring(s, i, i + 1);
            case ch == open_ch of {
                true -> find_matching(s, i + 1, open_ch, close_ch, depth + 1);
                false -> case ch == close_ch of {
                    true -> case depth == 1 of {
                        true -> i;
                        false -> find_matching(s, i + 1, open_ch, close_ch, depth - 1)
                    };
                    false -> find_matching(s, i + 1, open_ch, close_ch, depth)
                }
            }
        end
    }
}''',
    "find_matching_brackets": '''fn find_matching_brackets(s: string, i: int64, depth: int64) -> int64 {
    case i >= len(s) of {
        true -> 0 - 1;
        false -> do
            ch: string <- substring(s, i, i + 1);
            case ch == ch_lbracket() of {
                true -> find_matching_brackets(s, i + 1, depth + 1);
                false -> case ch == ch_rbracket() of {
                    true -> case depth == 1 of {
                        true -> i;
                        false -> find_matching_brackets(s, i + 1, depth - 1)
                    };
                    false -> find_matching_brackets(s, i + 1, depth)
                }
            }
        end
    }
}''',
    "find_matching_braces": '''fn find_matching_braces(s: string, i: int64, depth: int64) -> int64 {
    case i >= len(s) of {
        true -> 0 - 1;
        false -> do
            ch: string <- substring(s, i, i + 1);
            case ch == ch_lbrace() of {
                true -> find_matching_braces(s, i + 1, depth + 1);
                false -> case ch == ch_rbrace() of {
                    true -> case depth == 1 of {
                        true -> i;
                        false -> find_matching_braces(s, i + 1, depth - 1)
                    };
                    false -> find_matching_braces(s, i + 1, depth)
                }
            }
        end
    }
}''',
    "find_matching_parens": '''fn find_matching_parens(s: string, i: int64, depth: int64) -> int64 {
    case i >= len(s) of {
        true -> 0 - 1;
        false -> do
            ch: string <- substring(s, i, i + 1);
            case ch == "(" of {
                true -> find_matching_parens(s, i + 1, depth + 1);
                false -> case ch == ")" of {
                    true -> case depth == 1 of {
                        true -> i;
                        false -> find_matching_parens(s, i + 1, depth - 1)
                    };
                    false -> find_matching_parens(s, i + 1, depth)
                }
            }
        end
    }
}''',
}

GOOD_PARSE_LIST = '''fn parse_list_type(interner: TypeInterner, s: string) -> ParseResult {
    t0: string <- trim_type(s);
    rest0: string <- case starts_with(t0, "List") of {
        true -> trim_type(substring(t0, 4, len(t0)));
        false -> ""
    };
    t: string <- case starts_with(t0, "List") and starts_with(rest0, ch_lbracket()) of {
        true -> concat("List", rest0);
        false -> t0
    };
    list_pref: string <- concat("List", ch_lbracket());
    case starts_with(t, list_pref) of {
        false -> parse_fail(interner);
        true -> do
            close: int64 <- find_matching_brackets(t, 4, 0);
            case close < 0 of {
                true -> parse_fail(interner);
                false -> do
                    inner: string <- substring(t, 5, close);
                    cpos: int64 <- find_top_comma(inner, 0, 0, 0, 0);
                    case cpos < 0 of {
                        true -> do
                            er: ParseResult <- parse_type_inner(interner, trim_type(inner));
                            case er.ok of {
                                false -> er;
                                true -> do
                                    r: InternResult <- mk_list_legacy(er.interner, er.id);
                                    parse_ok(r.interner, r.id)
                                end
                            }
                        end;
                        false -> do
                            elem_s: string <- trim_type(substring(inner, 0, cpos));
                            space_s: string <- substring(inner, cpos + 1, len(inner));
                            er: ParseResult <- parse_type_inner(interner, elem_s);
                            case er.ok of {
                                false -> er;
                                true -> do
                                    sr: ParseResult <- parse_space_slot(er.interner, space_s);
                                    case sr.ok of {
                                        false -> sr;
                                        true -> do
                                            r: InternResult <- mk_list(sr.interner, er.id, sr.id);
                                            parse_ok(r.interner, r.id)
                                        end
                                    }
                                end
                            }
                        end
                    }
                end
            }
        end
    }
}'''

GOOD_NODES = '''fn node_kind(interner: TypeInterner, id: int64) -> int64 {
    case id < 0 of {
        true -> 0;
        false -> case id >= interner.next_id of {
            true -> 0;
            false -> do
                n: TypeNode <- nodes_at(interner.nodes, id);
                n.kind
            end
        }
    }
}

fn node_a(interner: TypeInterner, id: int64) -> int64 {
    case id < 0 or id >= interner.next_id of {
        true -> 0;
        false -> do
            n: TypeNode <- nodes_at(interner.nodes, id);
            n.a
        end
    }
}

fn node_b(interner: TypeInterner, id: int64) -> int64 {
    case id < 0 or id >= interner.next_id of {
        true -> 0;
        false -> do
            n: TypeNode <- nodes_at(interner.nodes, id);
            n.b
        end
    }
}

fn node_c(interner: TypeInterner, id: int64) -> int64 {
    case id < 0 or id >= interner.next_id of {
        true -> 0;
        false -> do
            n: TypeNode <- nodes_at(interner.nodes, id);
            n.c
        end
    }
}
'''


def strip_innermost_sequence_proc(text: str) -> tuple[str, int]:
    """Strip one innermost sequence-proc block; return (text, stripped_count)."""
    lines = text.split("\n")
    # Find sequence proc lines; pick the one with greatest indent
    candidates = []
    for i, line in enumerate(lines):
        if "sequence proc[mem(normal)]" in line:
            ind = len(line) - len(line.lstrip())
            candidates.append((ind, i))
    if not candidates:
        return text, 0
    candidates.sort(reverse=True)
    _, i = candidates[0]
    ind = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
    body = []
    j = i + 1
    while j < len(lines):
        if lines[j].startswith(ind + "produces"):
            j += 1
            if j >= len(lines):
                return text, 0
            res = lines[j].strip().replace("pure ", "").rstrip(";")
            j += 1
            if j < len(lines) and lines[j].strip() == "end":
                j += 1
            # Emit do/end (or flat if top-level indent)
            out = lines[:i]
            if ind == "    ":
                out.extend(body)
                out.append(ind + res)
            else:
                out.append(ind + "do")
                out.extend(body)
                out.append(ind + "    " + res)
                out.append(ind + "end")
            out.extend(lines[j:])
            return "\n".join(out), 1
        body.append(lines[j])
        j += 1
    return text, 0


def strip_all_sequence_procs(text: str) -> str:
    for _ in range(500):
        text, n = strip_innermost_sequence_proc(text)
        if n == 0:
            break
    return text


def fix_binding_braces_depth(text: str) -> str:
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s+)(true|false) -> \{\s*$", lines[i])
        if m and i + 1 < len(lines) and "<-" in lines[i + 1]:
            ind = m.group(1)
            j = i + 1
            depth = 1
            body = []
            while j < len(lines) and depth > 0:
                line = lines[j]
                opens = line.count("{")
                closes = line.count("}")
                if depth == 1 and opens == 0 and closes >= 1 and line.strip() in ("}", "};"):
                    semi = line.strip().endswith(";")
                    out.append(f"{ind}{m.group(2)} -> do")
                    out.extend(body)
                    out.append(f"{ind}end" + (";" if semi else ""))
                    i = j + 1
                    break
                depth += opens - closes
                body.append(line)
                j += 1
            else:
                out.append(lines[i])
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out)


def unwrap_do_in_braces(text: str) -> str:
    def once(t: str) -> tuple[str, int]:
        lines = t.split("\n")
        out = []
        i = 0
        changed = 0
        while i < len(lines):
            m = re.match(r"^(\s+)(true|false) -> \{\s*$", lines[i])
            if m:
                k = i + 1
                while k < len(lines) and lines[k].strip() == "":
                    k += 1
                if k < len(lines) and lines[k].strip() == "do":
                    ind = m.group(1)
                    j = k + 1
                    do_depth = 1
                    found = False
                    while j < len(lines):
                        s = lines[j].strip()
                        if s == "do" or re.search(r"-> do\s*$", s):
                            do_depth += 1
                        if s in ("end", "end;"):
                            do_depth -= 1
                            if do_depth == 0:
                                c = j + 1
                                while c < len(lines) and lines[c].strip() == "":
                                    c += 1
                                if c < len(lines) and re.match(r"^\s*\}\s*;?\s*$", lines[c]):
                                    out.append(f"{ind}{m.group(2)} -> do")
                                    out.extend(lines[k + 1 : j])
                                    semi = ";" if (s.endswith(";") or lines[c].strip().endswith(";")) else ""
                                    out.append(f"{ind}end{semi}")
                                    i = c + 1
                                    changed += 1
                                    found = True
                                    break
                                break
                        j += 1
                    if found:
                        continue
            out.append(lines[i])
            i += 1
        return "\n".join(out), changed

    for _ in range(50):
        text, n = once(text)
        if n == 0:
            break
    return text


def replace_fn(text: str, name: str, good: str) -> str:
    # Match top-level fn by scanning braces from the fn line
    lines = text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f"fn {name}(") or line.startswith(f"fn {name} ("):
            start = i
            break
    if start is None:
        print("WARN: missing", name)
        return text
    depth = 0
    started = False
    end = start
    for j in range(start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if "{" in lines[j]:
            started = True
        if started and depth == 0:
            end = j
            break
    return "\n".join(lines[:start] + good.split("\n") + lines[end + 1 :])


def add_binding_semicolons(text: str) -> str:
    out = []
    for line in text.splitlines():
        if (
            re.match(r"^\s+[A-Za-z_][A-Za-z0-9_]*:\s+.+\s<-\s.+$", line)
            and not line.rstrip().endswith(";")
            and not line.rstrip().endswith("{")
        ):
            out.append(line.rstrip() + ";")
        else:
            out.append(line)
    return "\n".join(out) + "\n"


def build_find_top(name: str, match_expr: str) -> str:
    """Generate find_top_comma / find_top_arrow / find_top_type_sum_bar style scanner."""
    return f'''fn {name}(s: string, i: int64, depth_paren: int64, depth_brack: int64, depth_brace: int64) -> int64 {{
    case i >= len(s) of {{
        true -> 0 - 1;
        false -> do
            ch: string <- substring(s, i, i + 1);
            case ch == "(" of {{
                true -> {name}(s, i + 1, depth_paren + 1, depth_brack, depth_brace);
                false -> case ch == ")" of {{
                    true -> {name}(s, i + 1, depth_paren - 1, depth_brack, depth_brace);
                    false -> case ch == ch_lbracket() of {{
                        true -> {name}(s, i + 1, depth_paren, depth_brack + 1, depth_brace);
                        false -> case ch == ch_rbracket() of {{
                            true -> {name}(s, i + 1, depth_paren, depth_brack - 1, depth_brace);
                            false -> case ch == ch_lbrace() of {{
                                true -> {name}(s, i + 1, depth_paren, depth_brack, depth_brace + 1);
                                false -> case ch == ch_rbrace() of {{
                                    true -> {name}(s, i + 1, depth_paren, depth_brack, depth_brace - 1);
                                    false -> case depth_paren == 0 and depth_brack == 0 and depth_brace == 0 and {match_expr} of {{
                                        true -> i;
                                        false -> {name}(s, i + 1, depth_paren, depth_brack, depth_brace)
                                    }}
                                }}
                            }}
                        }}
                    }}
                }}
            }}
        end
    }}
}}'''


def regenerate(out_path: Path) -> None:
    src = SELFHOST.read_text()
    src = src.replace("arg_a", "a").replace("arg_b", "b").replace("arg_c", "c")
    tmp = Path("/tmp/ti_for_boot.silica")
    tmp.write_text(src)

    # Core structural transform
    sys.argv = ["bootstrap_type_interner.py", str(tmp)]
    bt.main()
    t = tmp.read_text()

    t = strip_all_sequence_procs(t)
    # remove_head before head (substring trap)
    t = re.sub(r"remove_head\[int64,\s*mem\(normal\)\]\((\w+)\)", r"\1.tail", t)
    t = re.sub(r"head\[int64,\s*mem\(normal\)\]\((\w+)\)", r"\1.head", t)

    t = fx.remove_broken_empty_int_list(t)
    t = fx.fix_intern_result_literals(t)
    t = fx.fix_unwrap_space_id(t)
    t = fx.fix_empty_string_list_fn(t)
    t = t.replace("strings_at(", "lexemes_at(")
    t = fx.fix_fn_out_bodies(t)

    t = fix_binding_braces_depth(t)
    t = unwrap_do_in_braces(t)
    t = strip_all_sequence_procs(t)  # in case any remain after unwrap path
    t = unwrap_do_in_braces(t)

    for name, good in GOOD_SCANNERS.items():
        t = replace_fn(t, name, good)

    t = replace_fn(t, "find_top_comma", build_find_top("find_top_comma", 'ch == ","'))
    t = replace_fn(t, "find_top_arrow", build_find_top("find_top_arrow", 'substring(s, i, i + 2) == "->"'))
    t = replace_fn(t, "find_top_type_sum_bar", build_find_top("find_top_type_sum_bar", 'ch == "|"'))
    t = replace_fn(t, "parse_list_type", GOOD_PARSE_LIST)

    # node_*
    start = t.find("fn node_kind(interner:")
    end_c = t.find("fn node_c(interner:")
    rest = t[end_c:]
    m = re.search(r"\nfn (?!node_c)", rest[1:])
    t = t[:start] + GOOD_NODES + "\n" + t[end_c + 1 + m.start() :]
    t = t.replace(
        "{ kind: int64, a: int64, b: int64, c: int64, buf_size_is_name: boolean }",
        "TypeNode",
    )

    t = add_binding_semicolons(t)

    # Sanity
    assert 'find_top_comma(tin, 0, 0, 0, 0) < 0' in t, "atom-headed tuple parse fix missing"
    assert "sequence proc" not in t, "sequence proc remains"
    assert t.count("{") == t.count("}"), f"brace imbalance {t.count('{')} vs {t.count('}')}"

    out_path.write_text(t)
    print("wrote", out_path, "lines", t.count("\n") + 1)


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    regenerate(out)
