#!/usr/bin/env python3
"""Phase 3: expected_type int64 + check_expr returns (TypeCheckResult, TypeContext)."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent

EXPR_FILES = [
    ROOT / "expressions/type_checker_expressions.silica",
    ROOT / "expressions/type_checker_expressions_literals.silica",
    ROOT / "expressions/type_checker_expressions_identifiers.silica",
    ROOT / "expressions/type_checker_expressions_atoms.silica",
    ROOT / "expressions/boolean_type_checker_expressions.silica",
    ROOT / "expressions/type_checker_expressions_string_calls.silica",
    ROOT / "expressions/type_checker_expressions_float32_calls.silica",
    ROOT / "expressions/type_checker_expressions_actors.silica",
    ROOT / "type_checker_lists.silica",
    ROOT / "type_checker_collections.silica",
    ROOT / "declarations/type_checker_declarations_functions.silica",
]


def migrate_signatures(text: str) -> str:
    # check_expr signature
    text = re.sub(
        r"fn check_expr\(expr: Expr, expected_type: string, context: TypeContext, world: ListNamedProgram\) -> TypeCheckResult( proc\[DeviceIO\])?",
        r"fn check_expr(expr: Expr, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> (TypeCheckResult, TypeContext)\1",
        text,
    )
    # other helpers with expected_type: string that take context nearby — keep for now if no context
    # Broad: expected_type: string -> expected_type: int64 inside type_checker expression modules
    text = text.replace("expected_type: string", "expected_type: int64")
    return text


def migrate_types_equal_export(text: str, path: Path) -> str:
    if path.name == "type_checker_tuple_decompose_helpers.silica":
        text = text.replace("export types_equal/2;", "export types_equal_surface/2;")
        # rename fn types_equal(a: string, b: string)
        text = re.sub(
            r"\bfn types_equal\(a: string, b: string\)",
            "fn types_equal_surface(a: string, b: string)",
            text,
        )
        # call sites within file: types_equal( -> types_equal_surface( but not types_equal_surface already
        text = re.sub(r"(?<![\w@])types_equal\(", "types_equal_surface(", text)
        text = text.replace("types_equal_surface_surface(", "types_equal_surface(")
    return text


def fix_expr_add_symbol(text: str) -> str:
    # base_env <- add_symbol(context.env, name, surface, effects, "") ; then type_context_with_env
    text = re.sub(
        r"base_env: List\[[^\]]+\] <- type_checker_core@add_symbol\(context\.env, ([^,]+), ([^,]+), ([^,]+), ([^)]+)\);\n(\s*)([^\n]*type_checker_core@type_context_with_env\(context, base_env\))",
        r"ctx_bound: TypeContext <- type_checker_core@context_add_symbol_surface(context, \1, \2, \3, \4);\n\5\6".replace(
            "type_context_with_env(context, base_env)", "/*replaced*/"
        ),
        text,
    )
    # simpler replace patterns for known lines
    text = text.replace(
        "type_checker_core@add_symbol(context.env, expr.name, bind_type, parser_ast@empty_effect_name_list(), \"\")",
        "ERROR_ADD_SYMBOL_NEEDS_CONTEXT_BIND",
    )
    return text


def main() -> None:
    for path in EXPR_FILES:
        if not path.exists():
            print("missing", path)
            continue
        text = path.read_text(encoding="utf-8")
        orig = text
        text = migrate_signatures(text)
        if path.name.endswith("tuple_decompose_helpers.silica"):
            pass
        text = migrate_types_equal_export(text, path)
        if text != orig:
            path.write_text(text, encoding="utf-8")
            print("updated", path.relative_to(ROOT))
        else:
            print("unchanged", path.relative_to(ROOT))

    # tuple helpers separately
    tp = ROOT / "expressions/type_checker_tuple_decompose_helpers.silica"
    text = tp.read_text(encoding="utf-8")
    orig = text
    text = migrate_types_equal_export(text, tp)
    # also fix external refs to types_equal in other files
    if text != orig:
        tp.write_text(text, encoding="utf-8")
        print("updated tuple helpers types_equal rename")

    # Rename qualified calls across type_checker
    for path in ROOT.rglob("*.silica"):
        if path.name == "type_interner.silica":
            continue
        text = path.read_text(encoding="utf-8")
        orig = text
        text = text.replace(
            "type_checker_tuple_decompose_helpers@types_equal(",
            "type_checker_tuple_decompose_helpers@types_equal_surface(",
        )
        if text != orig:
            path.write_text(text, encoding="utf-8")
            print("renamed types_equal call in", path.relative_to(ROOT))


if __name__ == "__main__":
    main()
