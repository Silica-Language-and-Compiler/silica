#!/usr/bin/env python3
"""Fix Phase 3 expected_type int64 patterns in type_checker_expressions.silica and related files."""

from __future__ import annotations

import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src" / "type_checker"
EXPR = SRC / "expressions" / "type_checker_expressions.silica"


def fix_expressions(text: str) -> str:
    # Wrong ctx from automated script -> context (except lookup_supervisor_csv(ctx) in fn with ctx param)
    text = re.sub(
        r"type_checker_core@context_tid_(\w+)\(ctx\)",
        r"type_checker_core@context_tid_\1(context)",
        text,
    )

    # check_uint64_result / bool_result signatures and bodies
    text = text.replace(
        "fn check_uint64_result(expected_type: int64, location: SourceLocation, op_label: string) -> TypeCheckResult {\n"
        "    case expected_type of {\n"
        '        "uint64" -> type_checker_core@type_check_ok();\n'
        '        "discard" -> type_checker_core@type_check_ok();\n'
        '        _: string -> type_checker_core@type_check_err("E2003", location, concat(concat(op_label, " returns uint64, expected "), expected_type), "sect6")\n'
        "    }\n"
        "}",
        "fn check_uint64_result(context: TypeContext, expected_type: int64, location: SourceLocation, op_label: string) -> TypeCheckResult {\n"
        "    case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_uint64(context)) of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        '        false -> type_checker_core@type_check_err("E2003", location, concat(concat(op_label, " returns uint64, expected "), type_checker_core@type_id_to_surface(context, expected_type)), "sect6")\n'
        "    }\n"
        "}",
    )
    text = text.replace(
        "check_uint64_result(expected_type, expr.location, ",
        "check_uint64_result(context, expected_type, expr.location, ",
    )

    text = text.replace(
        "fn bool_result(expected_type: int64, location: SourceLocation) -> TypeCheckResult {\n"
        "    case expected_type of {\n"
        '        "boolean" -> type_checker_core@type_check_ok();\n'
        '        "discard" -> type_checker_core@type_check_ok();\n'
        '        _: string -> type_checker_core@type_check_err("E2003", location, concat("comparison op expects boolean result, got ", expected_type), "sect6")\n'
        "    }\n"
        "}",
        "fn bool_result(context: TypeContext, expected_type: int64, location: SourceLocation) -> TypeCheckResult {\n"
        "    case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_boolean(context)) of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        '        false -> type_checker_core@type_check_err("E2003", location, concat("comparison op expects boolean result, got ", type_checker_core@type_id_to_surface(context, expected_type)), "sect6")\n'
        "    }\n"
        "}",
    )
    text = text.replace(
        "bool_result(expected_type, expr.location)",
        "bool_result(context, expected_type, expr.location)",
    )

    # comparison operands: string surface -> parse at call site via helper variable pattern
    text = text.replace(
        "fn check_comparison_operands(expr: Expr, operand_type: string, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    left_result: TypeCheckResult <- check_expr(expr.inner, operand_type, context, world);\n"
        "    case left_result.is_ok of {\n"
        "        false -> left_result;\n"
        "        true -> check_expr(expr.right_expr, operand_type, context, world)\n"
        "    }\n"
        "}",
        "fn check_comparison_operands(expr: Expr, operand_type_id: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    left_result: TypeCheckResult <- check_expr(expr.inner, operand_type_id, context, world);\n"
        "    case left_result.is_ok of {\n"
        "        false -> left_result;\n"
        "        true -> check_expr(expr.right_expr, operand_type_id, context, world)\n"
        "    }\n"
        "}",
    )

    cmp_surfaces = [
        "boolean", "int64", "int32", "int16", "int8",
        "uint64", "uint32", "uint16", "uint8",
        "float32", "float16", "string", "atom",
    ]
    tid_map = {
        "boolean": "context_tid_boolean",
        "int64": "context_tid_int64",
        "uint64": "context_tid_uint64",
        "float32": "context_tid_float32",
        "float16": "context_tid_float16",
        "string": "context_tid_string",
        "atom": "context_tid_atom",
    }
    for surf in cmp_surfaces:
        old = f'check_comparison_operands(expr, "{surf}", context, world)'
        if surf in tid_map:
            new = f'check_comparison_operands(expr, type_checker_core@{tid_map[surf]}(context), context, world)'
        else:
            new = (
                f'do\n'
                f'                cmp_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, "{surf}");\n'
                f'                check_comparison_operands(expr, cmp_out.type_id, cmp_out.context, world)\n'
                f'            end'
            )
        text = text.replace(old, new)

    # check_runtime_builtin_return
    text = text.replace(
        "fn check_runtime_builtin_return(expr: Expr, inferred: string, expected_type: int64) -> TypeCheckResult {\n"
        "    disp: string <- type_checker_core@user_call_base_function_name(expr.name);\n"
        "    case type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_discard(context)) of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        "        false -> case type_checker_lists@types_equal_strip(inferred, expected_type) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        "            false -> type_checker_core@type_check_err(\"E2003\", expr.location, concat(concat(concat(concat(disp, \" returns \"), inferred), \", expected \"), expected_type), \"sect15\")\n"
        "        }\n"
        "    }\n"
        "}",
        "fn check_runtime_builtin_return(expr: Expr, inferred: string, expected_type: int64, context: TypeContext) -> TypeCheckResult {\n"
        "    disp: string <- type_checker_core@user_call_base_function_name(expr.name);\n"
        "    case type_checker_core@type_id_is_discard(context, expected_type) of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        "        false -> do\n"
        "            inf_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, inferred);\n"
        "            exp_surface: string <- type_checker_core@type_id_to_surface(context, expected_type);\n"
        "            case type_checker_core@types_equal_type_ids(expected_type, inf_out.type_id) of {\n"
        "                true -> type_checker_core@type_check_ok();\n"
        "                false -> case type_checker_lists@types_equal_strip(inferred, exp_surface) of {\n"
        "                    true -> type_checker_core@type_check_ok();\n"
        "                    false -> type_checker_core@type_check_err(\"E2003\", expr.location, concat(concat(concat(concat(disp, \" returns \"), inferred), \", expected \"), exp_surface), \"sect15\")\n"
        "                }\n"
        "            }\n"
        "        end\n"
        "    }\n"
        "}",
    )
    text = text.replace(
        "check_runtime_builtin_return(expr, inferred, expected_type)",
        "check_runtime_builtin_return(expr, inferred, expected_type, context)",
    )

    # spawn result type
    text = text.replace(
        "fn check_actor_spawn_result_type(expr: Expr, expected_type: int64, builtin_label: string, spawn_result_type: string) -> TypeCheckResult {\n"
        "    case expected_type == spawn_result_type of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        "        false -> case type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_discard(context)) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        "            false -> type_checker_core@type_check_err(\"E2003\", expr.location, concat(concat(concat(builtin_label, \" returns \"), spawn_result_type), concat(\", expected \", expected_type)), \"sect15\")\n"
        "        }\n"
        "    }\n"
        "}",
        "fn check_actor_spawn_result_type(expr: Expr, expected_type: int64, context: TypeContext, builtin_label: string, spawn_result_type: string) -> TypeCheckResult {\n"
        "    spawn_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, spawn_result_type);\n"
        "    case type_checker_core@types_equal_type_ids(expected_type, spawn_out.type_id) of {\n"
        "        true -> type_checker_core@type_check_ok();\n"
        "        false -> case type_checker_core@type_id_is_discard(context, expected_type) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        "            false -> type_checker_core@type_check_err(\"E2003\", expr.location, concat(concat(concat(builtin_label, \" returns \"), spawn_result_type), concat(\", expected \", type_checker_core@type_id_to_surface(context, expected_type))), \"sect15\")\n"
        "        }\n"
        "    }\n"
        "}",
    )
    text = text.replace(
        "check_actor_spawn_result_type(expr, expected_type, builtin_label, spawn_result_type)",
        "check_actor_spawn_result_type(expr, expected_type, context, builtin_label, spawn_result_type)",
    )
    text = text.replace(
        'check_actor_spawn_result_type(expr, expected_type, "spawn_linked", "actor_ref")',
        'check_actor_spawn_result_type(expr, expected_type, context, "spawn_linked", "actor_ref")',
    )
    text = text.replace(
        'check_supervisor_spawn_result_type(expr, expected_type, "spawn_registered_supervisor")',
        'check_supervisor_spawn_result_type(expr, expected_type, context, "spawn_registered_supervisor")',
    )

    # string literal kind 8
    text = text.replace(
        """        8 -> case len(expected_type) == 6 and substring(expected_type, 0, 1) == "s" and substring(expected_type, 1, 2) == "t" and substring(expected_type, 2, 3) == "r" and substring(expected_type, 3, 4) == "i" and substring(expected_type, 4, 5) == "n" and substring(expected_type, 5, 6) == "g" of {
            true -> type_checker_core@type_check_ok();
            false -> case len(expected_type) == 7 and substring(expected_type, 0, 1) == "d" and substring(expected_type, 1, 2) == "i" and substring(expected_type, 2, 3) == "s" and substring(expected_type, 3, 4) == "c" and substring(expected_type, 4, 5) == "a" and substring(expected_type, 5, 6) == "r" and substring(expected_type, 6, 7) == "d" of {
                true -> type_checker_core@type_check_ok();
                false -> type_checker_core@type_check_err("E2001", expr.location, concat("string literal requires string type, got ", case expected_type of { "" -> "[EMPTY]"; _: string -> expected_type }), "sect6")
            }
        };""",
        """        8 -> type_checker_expressions_string_calls@check_string_literal(expr, expected_type, context);""",
    )

    return text


def fix_string_calls(text: str) -> str:
    # Add context to functions that need type id checks - rewrite key functions
    replacements = [
        (
            "fn check_print_string_result_type(expected_type: int64, location: SourceLocation) -> TypeCheckResult {\n"
            "    case expected_type of {\n"
            '        "atom" -> type_checker_core@type_check_ok();\n'
            '        "discard" -> type_checker_core@type_check_ok();\n'
            '        _: string -> type_checker_core@type_check_err("E2003", location, concat("print_string expects atom result, got ", expected_type), "sect6")\n'
            "    }\n"
            "}",
            "fn check_print_string_result_type(context: TypeContext, expected_type: int64, location: SourceLocation) -> TypeCheckResult {\n"
            "    case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_atom(context)) of {\n"
            "        true -> type_checker_core@type_check_ok();\n"
            '        false -> type_checker_core@type_check_err("E2003", location, concat("print_string expects atom result, got ", type_checker_core@type_id_to_surface(context, expected_type)), "sect6")\n'
            "    }\n"
            "}",
        ),
        (
            "fn check_string_literal(expr: Expr, expected_type: int64, context: TypeContext) -> TypeCheckResult {\n"
            "    case is_string_type_name(expected_type) of {\n"
            "        true -> type_checker_core@type_check_ok();\n"
            "        false -> case is_discard_type_name(expected_type) of {\n"
            "            true -> type_checker_core@type_check_ok();\n"
            '            false -> type_checker_core@type_check_err("E2001", expr.location, concat("string literal requires string type, got ", case expected_type of { "" -> "[EMPTY]"; _: string -> expected_type }), "sect6")\n'
            "        }\n"
            "    }\n"
            "}",
            "fn check_string_literal(expr: Expr, expected_type: int64, context: TypeContext) -> TypeCheckResult {\n"
            "    case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_string(context)) of {\n"
            "        true -> type_checker_core@type_check_ok();\n"
            '        false -> type_checker_core@type_check_err("E2001", expr.location, concat("string literal requires string type, got ", type_checker_core@type_id_to_surface(context, expected_type)), "sect6")\n'
            "    }\n"
            "}",
        ),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def fix_float32_calls(text: str) -> str:
    return text.replace(
        "fn check_print_float32_call(expr: Expr, expected_type: int64, arg_result: TypeCheckResult) -> TypeCheckResult {\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case expected_type of {\n"
        '            "atom" -> type_checker_core@type_check_ok();\n'
        '            "discard" -> type_checker_core@type_check_ok();\n'
        '            _: string -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(expr.name, " expects atom result, got "), expected_type), "sect6")\n'
        "        }\n"
        "    }\n"
        "}",
        "fn check_print_float32_call(expr: Expr, expected_type: int64, context: TypeContext, arg_result: TypeCheckResult) -> TypeCheckResult {\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_atom(context)) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        '            false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(expr.name, " expects atom result, got "), type_checker_core@type_id_to_surface(context, expected_type)), "sect6")\n'
        "        }\n"
        "    }\n"
        "}",
    )


def fix_atoms(text: str) -> str:
    text = re.sub(
        r"type_checker_core@context_tid_atom\(ctx\)",
        "type_checker_core@context_tid_atom(context)",
        text,
    )
    text = re.sub(
        r"type_checker_core@context_tid_discard\(ctx\)",
        "type_checker_core@context_tid_discard(context)",
        text,
    )
    return text.replace(
        'concat("atom literal requires atom return type, got ", case expected_type of { "" -> "[EMPTY]"; _: string -> expected_type })',
        'concat("atom literal requires atom return type, got ", type_checker_core@type_id_to_surface(context, expected_type))',
    )


def fix_lists(text: str) -> str:
    return text.replace(
        "fn resolve_list_type_from_collectable_generic(elem: string, space: string, expected_type: int64) -> (bool, string, string, string) {",
        "fn resolve_list_type_from_collectable_generic(elem: string, space: string, expected_type: int64, context: TypeContext) -> (bool, string, string, string) {",
    ).replace(
        "type_checker_core@context_tid_discard(ctx)",
        "type_checker_core@context_tid_discard(context)",
    ).replace(
        "(ok_e: bool, ee: string, es: string) <- parse_list_type_params(expected_type);",
        "exp_surface: string <- type_checker_core@type_id_to_surface(context, expected_type);\n                (ok_e: bool, ee: string, es: string) <- parse_list_type_params(exp_surface);",
    )


def main() -> None:
    expr_text = EXPR.read_text()
    expr_text = fix_expressions(expr_text)
    EXPR.write_text(expr_text)

    p = SRC / "expressions" / "type_checker_expressions_string_calls.silica"
    p.write_text(fix_string_calls(p.read_text()))

    p = SRC / "expressions" / "type_checker_expressions_float32_calls.silica"
    p.write_text(fix_float32_calls(p.read_text()))

    p = SRC / "expressions" / "type_checker_expressions_atoms.silica"
    p.write_text(fix_atoms(p.read_text()))

    p = SRC / "type_checker_lists.silica"
    p.write_text(fix_lists(p.read_text()))

    print("Applied phase 3 expression fixes")


if __name__ == "__main__":
    main()
