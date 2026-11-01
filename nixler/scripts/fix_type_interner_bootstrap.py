#!/usr/bin/env python3
"""Post-process bootstrap type_interner.silica to fix transform artifacts."""
import re
import sys

sys.path.insert(0, '/Volumes/2T/silica/compiler/scripts')
import bootstrap_type_interner as bt


def fix_intern_result_literals(text):
    text = text.replace(
        '{ interner: interner, id: interner.seq_nil_id }',
        'InternResult { interner: interner, id: interner.seq_nil_id }',
    )
    text = re.sub(
        r'-> \{ interner: interner, id: acc \}',
        '-> InternResult { interner: interner, id: acc }',
        text,
    )
    text = re.sub(
        r'\{ interner: ([^,]+), ids: ([^,]+), ok: (true|false) \}',
        r'IdListResult { interner: \1, ids: \2, ok: \3 }',
        text,
    )
    text = re.sub(
        r'\{ interner: ([^,]+), args: ([^,]+), ok: (true|false) \}',
        r'BracketArgsResult { interner: \1, args: \2, ok: \3 }',
        text,
    )
    text = re.sub(
        r'result: IdListResult <- \{\s*\n(\s+)interner:',
        r'result: IdListResult <- IdListResult {\n\1interner:',
        text,
    )
    text = re.sub(
        r'result: BracketArgsResult <- \{\s*\n(\s+)interner:',
        r'result: BracketArgsResult <- BracketArgsResult {\n\1interner:',
        text,
    )
    return text


def remove_broken_empty_int_list(text):
    return re.sub(
        r'\nfn empty_int_list\(\) -> ListInt64Entry \{\n\s+result: ListInt64Entry <- empty_int_list\(\)\n\s+result\n\}\n',
        '\n',
        text,
        count=1,
    )


def fix_fn_out_bodies(text):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        if lines[i].startswith('fn ') and i + 2 < len(lines):
            fn_lines = [lines[i]]
            i += 1
            depth = 0
            body = []
            while i < len(lines):
                fn_lines.append(lines[i])
                if lines[i].strip() == '}' and depth == 0:
                    break
                depth += lines[i].count('{') - lines[i].count('}')
                body.append(lines[i])
                i += 1
            if (
                len(body) >= 2
                and body[-1].strip() == 'out'
                and 'out:' in body[-2]
                and '<-' in body[-2]
            ):
                new_body = []
                for bl in body[:-2]:
                    s = bl.strip()
                    if s and not s.startswith('//'):
                        if '<-' in s and not s.endswith(';'):
                            bl = bl.rstrip() + ';'
                        new_body.append(bl)
                expr = body[-2].split('<-', 1)[1].strip().rstrip(';')
                fn_lines = [fn_lines[0]] + new_body + ['    ' + expr, '}']
            out.extend(fn_lines)
            i += 1
            continue
        out.append(lines[i])
        i += 1
    return '\n'.join(out)


def fix_do_in_braces(text):
    text = re.sub(
        r'(\s+)(true|false) -> \{\s*\n(\s+)do\n',
        r'\1\2 -> do\n',
        text,
    )
    text = re.sub(
        r'(\s+)end\s*\n(\s+)\}\s*;',
        r'\1end;',
        text,
    )
    text = re.sub(
        r'(\s+)end\s*\n(\s+)\}\s*\n(\s+)\}',
        r'\1end\n\3}',
        text,
    )
    return text


def fix_unwrap_space_id(text):
    old = """    case k == kind_mem() of {
        true -> do
            inner: int64 <- node_a(interner, id);
            case is_space_kind(node_kind(interner, inner)) of {
                true -> { id: inner, ok: true };
                false -> { id: invalid_type_id(), ok: false }
        end
        };"""
    new = """    case k == kind_mem() of {
        true -> do
            inner: int64 <- node_a(interner, id);
            case is_space_kind(node_kind(interner, inner)) of {
                true -> { id: inner, ok: true };
                false -> { id: invalid_type_id(), ok: false }
            }
        end;"""
    return text.replace(old, new)


def fix_empty_string_list_fn(text):
    return text.replace(
        'fn empty_string_list() -> ListStringEntry {\n    empty_strings()\n}',
        'fn empty_string_list() -> ListStringEntry {\n    empty_lexeme_list()\n}',
    )


def main():
    path = sys.argv[1]
    content = open(path).read()
    content = remove_broken_empty_int_list(content)
    content = bt.strip_sequence_proc(content)
    content = fix_intern_result_literals(content)
    content = fix_do_in_braces(content)
    content = fix_unwrap_space_id(content)
    content = fix_empty_string_list_fn(content)
    content = content.replace('strings_at(', 'lexemes_at(')
    content = fix_fn_out_bodies(content)
    open(path, 'w').write(content)
    print('fixed', path, 'lines', content.count('\n') + 1)


if __name__ == '__main__':
    main()
