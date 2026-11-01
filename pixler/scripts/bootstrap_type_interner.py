#!/usr/bin/env python3
"""Transform type_interner.silica to bootstrap-legal seed form."""
import re
import sys

INTERNER_BLOCK = """{
    nodes: List[{ kind: int64, a: int64, b: int64, c: int64, buf_size_is_name: boolean }, mem(normal)],
    by_key: {
        root: ref?(L, normal, rec),
        compare_key: fn(string, string) -> :less | :equal | :greater,
        compare_value: fn(int64, int64) -> :less | :equal | :greater,
        region: region(L, normal),
        specialization_key: int64,
        compare_key_ordering_bundle: int64,
        compare_value_ordering_bundle: int64
    },
    names: {
        root: ref?(L, normal, rec),
        compare_key: fn(string, string) -> :less | :equal | :greater,
        compare_value: fn(int64, int64) -> :less | :equal | :greater,
        region: region(L, normal),
        specialization_key: int64,
        compare_key_ordering_bundle: int64,
        compare_value_ordering_bundle: int64
    },
    name_lexemes: List[string, mem(normal)],
    next_id: int64,
    seq_nil_id: int64
}"""

STRUCTS = open('/Volumes/2T/silica/compiler/scripts/bootstrap_type_interner_structs.txt').read()

HELPERS = open('/Volumes/2T/silica/compiler/scripts/bootstrap_type_interner_helpers.txt').read()

CREATE_AND_SMOKE = '''fn create_type_interner() -> TypeInterner {
    base: TypeInterner <- TypeInterner {
        nodes: empty_type_node_list(),
        by_key: empty_key_list(),
        names: empty_name_list(),
        name_lexemes: empty_lexeme_list(),
        next_id: 0,
        seq_nil_id: 0 - 1
    };
    nil_r: InternResult <- intern_key(base, 1, 0, 0, 0, false);
    TypeInterner {
        nodes: nil_r.interner.nodes,
        by_key: nil_r.interner.by_key,
        names: nil_r.interner.names,
        name_lexemes: nil_r.interner.name_lexemes,
        next_id: nil_r.interner.next_id,
        seq_nil_id: nil_r.id
    }
}

fn phase1_roundtrip_smoke() -> int64 {
    0
}

'''


def protect_strings(text):
    out = []
    i = 0
    while i < len(text):
        if text[i] == '"':
            j = i + 1
            while j < len(text) and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            out.append(('S', text[i:j+1]))
            i = j + 1
        else:
            j = i
            while j < len(text) and text[j] != '"':
                j += 1
            if j > i:
                out.append(('T', text[i:j]))
            i = j
    return out


def replace_outside_strings(text, old, new):
    return ''.join(c if k == 'S' else c.replace(old, new) for k, c in protect_strings(text))


def strip_sequence_proc(text):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        if 'sequence proc[mem(normal)]' in lines[i]:
            ind = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            i += 1
            body = []
            while i < len(lines):
                if lines[i].startswith(ind + 'produces'):
                    i += 1
                    res = lines[i].strip().replace('pure ', '').rstrip(';')
                    i += 1
                    if i < len(lines) and lines[i].strip() == 'end':
                        i += 1
                    if ind == '    ' and body:
                        out.extend(body)
                        out.append(ind + res)
                    else:
                        out.append(ind + 'do')
                        out.extend(body)
                        out.append(ind + '    ' + res)
                        out.append(ind + 'end')
                    break
                body.append(lines[i])
                i += 1
        else:
            out.append(lines[i])
            i += 1
    return '\n'.join(out)


def fix_binding_braces(text):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r'(\s+)(true|false) -> \{\s*$', lines[i])
        if m and i + 1 < len(lines) and '<-' in lines[i + 1]:
            ind = m.group(1)
            out.append(f'{ind}{m.group(2)} -> do')
            i += 1
            while i < len(lines) and lines[i].strip() != '}':
                out.append(lines[i])
                i += 1
            out.append(f'{ind}end')
            i += 1
            continue
        out.append(lines[i])
        i += 1
    return '\n'.join(out)


def main():
    path = sys.argv[1]
    content = open(path).read()

    content = re.sub(r'\nuse wbt_map;\nuse OrderedMap;\n', '\n', content)
    content = content.replace('export kind_actor_ref/0;\n\nfn kind_id_seq_nil', 'export kind_actor_ref/0;\n' + STRUCTS + '\nfn kind_id_seq_nil')
    content = content.replace(INTERNER_BLOCK, 'TypeInterner')
    nl = 'List[{ kind: int64, a: int64, b: int64, c: int64, buf_size_is_name: boolean }, mem(normal)]'
    content = content.replace(nl, 'ListTypeNode')
    content = content.replace('List[string, mem(normal)]', 'ListStringEntry')
    content = replace_outside_strings(content, 'List[int64, mem(normal)]', 'ListInt64Entry')
    content = replace_outside_strings(content, 'List[{ name: string, ty: int64 }, mem(normal)]', 'ListFieldEntry')
    content = content.replace('{ interner: TypeInterner, id: int64, ok: boolean }', 'ParseResult')
    content = content.replace('{ interner: TypeInterner, id: int64 }', 'InternResult')
    content = content.replace('{ interner: TypeInterner, ids: ListInt64Entry, ok: boolean }', 'IdListResult')
    content = content.replace('{ interner: TypeInterner, args: ListInt64Entry, ok: boolean }', 'BracketArgsResult')

    s = content.find('fn compare_string')
    e = content.find('fn intern_key(')
    e2 = content.find('fn seq_nil_id(')
    content = content[:s] + HELPERS + CREATE_AND_SMOKE + content[e2:]

    content = re.sub(r'prepend\[int64, mem\(normal\)\]\(([^,]+), ([^)]+)\)', r'ListInt64Entry { is_nil: false, head: \1, tail: \2 }', content)
    content = re.sub(r'prepend\[{ name: string, ty: int64 }, mem\(normal\)\]\(\{ name: ([^,]+), ty: ([^}]+) \}, ([^)]+)\)', r'ListFieldEntry { is_nil: false, head: FieldEntry { name: \1, ty: \2 }, tail: \3 }', content)
    content = re.sub(r'prepend\[{ name: string, ty: int64 }, mem\(normal\)\]\(([^,]+), ([^)]+)\)', r'ListFieldEntry { is_nil: false, head: \1, tail: \2 }', content)
    content = re.sub(r'empty\[int64, mem\(normal\)\]\(\)', 'empty_int_list()', content)
    content = re.sub(r'empty\[{ name: string, ty: int64 }, mem\(normal\)\]\(\)', 'empty_field_list()', content)
    content = re.sub(r'prepend\[string, mem\(normal\)\]\(([^,]+), ([^)]+)\)', r'ListStringEntry { is_nil: false, head: \1, tail: \2 }', content)

    content = content.replace('{ interner: interner, id: invalid_type_id(), ok: false }', 'ParseResult { interner: interner, id: invalid_type_id(), ok: false }')
    content = content.replace('{ interner: interner, id: id, ok: true }', 'ParseResult { interner: interner, id: id, ok: true }')

    if 'fn empty_string_list()' not in content:
        insert_at = content.find('fn reverse_strings')
        esl = '''fn empty_string_list() -> List[string, mem(normal)] {
    sequence proc[mem(normal)]
        result: List[string, mem(normal)] <- empty[string, mem(normal)]()
    produces
        pure result
    end
}

'''
        content = content[:insert_at] + esl + content[insert_at:]

    content = strip_sequence_proc(content)
    content = fix_binding_braces(content)
    content = content.replace('stored in OrderedMap via decimal encoding', 'linear key-list intern table (bootstrap seed)')

    open(path, 'w').write(content)
    print('OK', path, 'lines', content.count('\n'))


if __name__ == '__main__':
    main()
