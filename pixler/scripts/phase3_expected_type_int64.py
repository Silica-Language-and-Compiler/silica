#!/usr/bin/env python3
"""Phase 3: convert expected_type: string -> int64 in type_checker sources."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src" / "type_checker"

LITERAL_TO_TID = {
    "int64": "type_checker_core@context_tid_int64(context)",
    "boolean": "type_checker_core@context_tid_boolean(context)",
    "string": "type_checker_core@context_tid_string(context)",
    "discard": "type_checker_core@context_tid_discard(context)",
    "atom": "type_checker_core@context_tid_atom(context)",
    "uint64": "type_checker_core@context_tid_uint64(context)",
    "float32": "type_checker_core@context_tid_float32(context)",
    "float16": "type_checker_core@context_tid_float16(context)",
    "char": "type_checker_core@context_tid_char(context)",
    "actor_ref": "type_checker_core@context_tid_actor_ref(context)",
    "supervisor_ref": "type_checker_core@context_tid_supervisor_ref(context)",
    "monitor_ref": "type_checker_core@context_tid_monitor_ref(context)",
    "List[int64,normal]": "type_checker_core@context_tid_list_int64_normal(context)",
}


def convert_file(path: Path) -> bool:
    text = path.read_text()
    orig = text

    text = text.replace("expected_type: string", "expected_type: int64")

    # Rename exported surface equality helper references in type_checker tree
    text = re.sub(
        r"type_checker_tuple_decompose_helpers@types_equal\(",
        "type_checker_tuple_decompose_helpers@types_equal_surface(",
        text,
    )
    text = re.sub(
        r"(?<![@\w])types_equal\(",
        "types_equal_surface(",
        text,
    ) if path.name == "type_checker_tuple_decompose_helpers.silica" else text

    # check_expr(..., "literal", context -> tid helper
    for lit, repl in LITERAL_TO_TID.items():
        esc = re.escape(lit)
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*context',
            rf"check_expr(\1, {repl}, context",
            text,
        )
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*ctx',
            rf"check_expr(\1, {repl}, ctx",
            text,
        )
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*ext_ctx',
            rf"check_expr(\1, {repl}, ext_ctx",
            text,
        )
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*body_ctx',
            rf"check_expr(\1, {repl}, body_ctx",
            text,
        )
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*ctx_params',
            rf"check_expr(\1, {repl}, ctx_params",
            text,
        )
        text = re.sub(
            rf'check_expr\(([^,]+),\s*"{esc}"\s*,\s*new_context',
            rf"check_expr(\1, {repl}, new_context",
            text,
        )

    # expected_type == "literal" -> types_equal_type_ids or eq_or_discard patterns (simple cases)
    for lit, repl in LITERAL_TO_TID.items():
        esc = re.escape(lit)
        tid_expr = repl.replace("context", "ctx")
        text = re.sub(
            rf'expected_type == "{esc}"',
            f"type_checker_core@types_equal_type_ids(expected_type, {tid_expr})",
            text,
        )

    # expected_type == "a" or expected_type == "b" (two-literal or patterns) - manual follow-up

    if text != orig:
        path.write_text(text)
        return True
    return False


def rename_types_equal_export(path: Path) -> None:
    if path.name != "type_checker_tuple_decompose_helpers.silica":
        return
    text = path.read_text()
    text = text.replace("export types_equal/2;", "export types_equal_surface/2;")
    text = text.replace("fn types_equal_surface(a: string, b: string)", "fn types_equal_surface(a: string, b: string)")
    if "fn types_equal(a: string, b: string)" in text:
        text = text.replace("fn types_equal(a: string, b: string)", "fn types_equal_surface(a: string, b: string)")
    path.write_text(text)


def main() -> None:
    changed = []
    for path in sorted(ROOT.rglob("*.silica")):
        rename_types_equal_export(path)
        if convert_file(path):
            changed.append(path.relative_to(ROOT.parent))
    print(f"Updated {len(changed)} files")
    for p in changed:
        print(f"  {p}")


if __name__ == "__main__":
    main()
