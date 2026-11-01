#!/usr/bin/env python3
"""Mechanical Phase 2+3 type-shape migration for type_checker/*.silica."""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

SYM_OLD = (
    "name: string, type_name: string, declared_effects: List[{ name: string, parameter: string, "
    "location: { file: string, line: int64, column: int64, offset: int64 } }, mem(normal)], "
    "is_effect_alias: bool, source_module: string"
)
SYM_NEW = (
    "name: string, type_id: int64, surface_type: string, declared_effects: List[{ name: string, parameter: string, "
    "location: { file: string, line: int64, column: int64, offset: int64 } }, mem(normal)], "
    "is_effect_alias: bool, source_module: string"
)

INTERNER_1L = (
    "{ nodes: List[{ kind: int64, a: int64, b: int64, c: int64, buf_size_is_name: boolean }, mem(normal)], "
    "by_key: { root: ref?(L, normal, rec), compare_key: fn(string, string) -> :less | :equal | :greater, "
    "compare_value: fn(int64, int64) -> :less | :equal | :greater, region: region(L, normal), "
    "specialization_key: int64, compare_key_ordering_bundle: int64, compare_value_ordering_bundle: int64 }, "
    "names: { root: ref?(L, normal, rec), compare_key: fn(string, string) -> :less | :equal | :greater, "
    "compare_value: fn(int64, int64) -> :less | :equal | :greater, region: region(L, normal), "
    "specialization_key: int64, compare_key_ordering_bundle: int64, compare_value_ordering_bundle: int64 }, "
    "name_lexemes: List[string, mem(normal)], next_id: int64, seq_nil_id: int64 }"
)

CTX_OLD = "{ env: List[{ " + SYM_NEW + " }, mem(normal)] }"
CTX_NEW = "{ env: List[{ " + SYM_NEW + " }, mem(normal)], interner: " + INTERNER_1L + " }"

SKIP = {
    os.path.basename(__file__),
    "type_interner.silica",
}


def migrate_text(text: str, path: str) -> str:
    if path.endswith("type_interner.silica"):
        return text
    n = text.count(SYM_OLD)
    text = text.replace(SYM_OLD, SYM_NEW)
    c = text.count(CTX_OLD)
    text = text.replace(CTX_OLD, CTX_NEW)
    # Field access on symbol rows: env.head.type_name -> prefer type_id for lookups.
    # Do NOT touch AST param type_name (params.head.type_name, p.type_name, source_params, etc.)
    # Only rewrite env.head.type_name and similar env-symbol patterns.
    for old, new in [
        ("env.head.type_name", "env.head.type_id"),
        ("context.env.head.type_name", "context.env.head.type_id"),
    ]:
        text = text.replace(old, new)
    print(f"{os.path.relpath(path, ROOT)}: sym={n} ctx={c}")
    return text


def main() -> int:
    changed = 0
    for dirpath, _, files in os.walk(ROOT):
        for f in files:
            if not f.endswith(".silica") or f in SKIP:
                continue
            path = os.path.join(dirpath, f)
            old = open(path, encoding="utf-8").read()
            new = migrate_text(old, path)
            if new != old:
                open(path, "w", encoding="utf-8").write(new)
                changed += 1
    print(f"updated {changed} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
