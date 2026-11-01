#!/usr/bin/env python3
"""Second pass: fix int64/string mismatches in Phase 3 type checker cutover."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src" / "type_checker"
EXPR = ROOT / "expressions" / "type_checker_expressions.silica"


HELPERS = """
fn expected_type_surface(context: TypeContext, expected_type: int64) -> string {
    type_checker_core@type_id_to_surface(context, expected_type)
}

fn check_expr_surface_type(expr: Expr, surface: string, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {
    parse_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, surface);
    check_expr(expr, parse_out.type_id, parse_out.context, world)
}

fn surface_type_matches_expected(context: TypeContext, surface: string, expected_type: int64) -> bool {
    parse_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, surface);
    case type_checker_core@types_equal_type_ids(expected_type, parse_out.type_id) of {
        true -> true;
        false -> type_checker_tuple_decompose_helpers@types_equal_surface(surface, expected_type_surface(context, expected_type))
    }
}

"""


def insert_helpers(text: str) -> str:
    marker = "export dispatch_actual_fits_impl_parameter/3;\n\n"
    if "fn expected_type_surface(" in text:
        return text
    return text.replace(marker, marker + HELPERS)


def fix_arithmetic_block(text: str) -> str:
    old = """        true -> do
            operand_type: string <- case expected_type of {
                "int64" -> "int64";
                "int32" -> "int32";
                "int16" -> "int16";
                "int8" -> "int8";
                "uint64" -> "uint64";
                "uint32" -> "uint32";
                "uint16" -> "uint16";
                "uint8" -> "uint8";
                "float64" -> "float64";
                "float32" -> "float32";
                "float16" -> "float16";
                _: string -> "int64"
            };
            left_result: TypeCheckResult <- check_expr(expr.inner, operand_type, context, world);
            case left_result.is_ok of {
                false -> left_result;
                true -> do
                    right_result: TypeCheckResult <- check_expr(expr.right_expr, operand_type, context, world);
                    case right_result.is_ok of {
                        false -> right_result;
                        true -> case expected_type of {
                            "int64" -> type_checker_core@type_check_ok();
                            "int32" -> type_checker_core@type_check_ok();
                            "int16" -> type_checker_core@type_check_ok();
                            "int8" -> type_checker_core@type_check_ok();
                            "uint64" -> type_checker_core@type_check_ok();
                            "uint32" -> type_checker_core@type_check_ok();
                            "uint16" -> type_checker_core@type_check_ok();
                            "uint8" -> type_checker_core@type_check_ok();
                            "float64" -> type_checker_core@type_check_ok();
                            "float32" -> type_checker_core@type_check_ok();
                            "float16" -> type_checker_core@type_check_ok();
                            "discard" -> type_checker_core@type_check_ok();
                            _: string -> type_checker_core@type_check_err("E2003", expr.location, concat("arithmetic op expects integer or float result (int64/.../float64/float32/float16), got ", expected_type), "sect6")
                        }
                    }
                end
            }
        end;"""
    new = """        true -> do
            exp_surface: string <- expected_type_surface(context, expected_type);
            operand_surface: string <- case exp_surface of {
                "int64" -> "int64";
                "int32" -> "int32";
                "int16" -> "int16";
                "int8" -> "int8";
                "uint64" -> "uint64";
                "uint32" -> "uint32";
                "uint16" -> "uint16";
                "uint8" -> "uint8";
                "float64" -> "float64";
                "float32" -> "float32";
                "float16" -> "float16";
                _: string -> "int64"
            };
            op_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, operand_surface);
            left_result: TypeCheckResult <- check_expr(expr.inner, op_out.type_id, op_out.context, world);
            case left_result.is_ok of {
                false -> left_result;
                true -> do
                    right_result: TypeCheckResult <- check_expr(expr.right_expr, op_out.type_id, op_out.context, world);
                    case right_result.is_ok of {
                        false -> right_result;
                        true -> case type_checker_core@type_id_is_discard(context, expected_type) of {
                            true -> type_checker_core@type_check_ok();
                            false -> case exp_surface of {
                                "int64" -> type_checker_core@type_check_ok();
                                "int32" -> type_checker_core@type_check_ok();
                                "int16" -> type_checker_core@type_check_ok();
                                "int8" -> type_checker_core@type_check_ok();
                                "uint64" -> type_checker_core@type_check_ok();
                                "uint32" -> type_checker_core@type_check_ok();
                                "uint16" -> type_checker_core@type_check_ok();
                                "uint8" -> type_checker_core@type_check_ok();
                                "float64" -> type_checker_core@type_check_ok();
                                "float32" -> type_checker_core@type_check_ok();
                                "float16" -> type_checker_core@type_check_ok();
                                _: string -> type_checker_core@type_check_err("E2003", expr.location, concat("arithmetic op expects integer or float result (int64/.../float64/float32/float16), got ", exp_surface), "sect6")
                            }
                        }
                    }
                end
            }
        end;"""
    return text.replace(old, new)


def fix_logical_block(text: str) -> str:
    old = """                            true -> case expected_type of {
                                "boolean" -> type_checker_core@type_check_ok();
                                "discard" -> type_checker_core@type_check_ok();
                                _: string -> type_checker_core@type_check_err("E2003", expr.location, concat("logical op expects boolean result, got ", expected_type), "sect6")
                            }"""
    new = """                            true -> case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_boolean(context)) of {
                                true -> type_checker_core@type_check_ok();
                                false -> type_checker_core@type_check_err("E2003", expr.location, concat("logical op expects boolean result, got ", expected_type_surface(context, expected_type)), "sect6")
                            }"""
    return text.replace(old, new)


def fix_print_and_negate(text: str) -> str:
    text = text.replace(
        "fn check_print_call(expr: Expr, arg_type: string, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    arg_result: TypeCheckResult <- check_expr(expr.inner, arg_type, context, world);\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case expected_type of {\n"
        '            "atom" -> type_checker_core@type_check_ok();\n'
        '            "discard" -> type_checker_core@type_check_ok();\n'
        '            _: string -> type_checker_core@type_check_err("E2003", expr.location, concat(concat("print_", concat(arg_type, " expects atom result, got ")), expected_type), "sect6")\n'
        "        }\n"
        "    }\n"
        "}",
        "fn check_print_call(expr: Expr, arg_type: string, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    arg_result: TypeCheckResult <- check_expr_surface_type(expr.inner, arg_type, context, world);\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_atom(context)) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        '            false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat("print_", concat(arg_type, " expects atom result, got ")), expected_type_surface(context, expected_type)), "sect6")\n'
        "        }\n"
        "    }\n"
        "}",
    )
    text = text.replace(
        "fn check_negate_call(expr: Expr, num_type: string, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    arg_result: TypeCheckResult <- check_expr(expr.inner, num_type, context, world);\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case expected_type of {\n"
        '            "discard" -> type_checker_core@type_check_ok();\n'
        "            _: string -> case expected_type == num_type of {\n"
        "                true -> type_checker_core@type_check_ok();\n"
        '                false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(concat(concat(expr.name, " returns "), num_type), ", expected "), expected_type), "sect6")\n'
        "            }\n"
        "        }\n"
        "    }\n"
        "}",
        "fn check_negate_call(expr: Expr, num_type: string, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    num_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, num_type);\n"
        "    arg_result: TypeCheckResult <- check_expr(expr.inner, num_out.type_id, num_out.context, world);\n"
        "    case arg_result.is_ok of {\n"
        "        false -> arg_result;\n"
        "        true -> case type_checker_core@type_id_is_discard(context, expected_type) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        "            false -> case type_checker_core@types_equal_type_ids(expected_type, num_out.type_id) of {\n"
        "                true -> type_checker_core@type_check_ok();\n"
        '                false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(concat(concat(expr.name, " returns "), num_type), ", expected "), expected_type_surface(context, expected_type)), "sect6")\n'
        "            }\n"
        "        }\n"
        "    }\n"
        "}",
    )
    return text


def fix_region_builtin_header(text: str) -> str:
    old = "fn check_region_builtin_call(expr: Expr, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n    case expr.name == \"alloc_region\" of {"
    new = (
        "fn check_region_builtin_call(expr: Expr, expected_type: int64, context: TypeContext, world: ListNamedProgram) -> TypeCheckResult proc[DeviceIO] {\n"
        "    expected_surface: string <- expected_type_surface(context, expected_type);\n"
        "    case expr.name == \"alloc_region\" of {"
    )
    if old in text and "expected_surface: string <- expected_type_surface" not in text.split("check_region_builtin_call")[1][:400]:
        text = text.replace(old, new)
    # memory region calls expecting string
    for fn in [
        "validate_memory_region_type",
        "get_space_from_region_type",
        "ref_type_to_region_type",
        "extract_element_type_from_ref",
        "buf_type_to_region_type",
        "extract_element_type_from_buf",
    ]:
        text = text.replace(f"@validate_memory_region_type(expected_type,", f"@validate_memory_region_type(expected_surface,")
        text = text.replace(f"@{fn}(expected_type)", f"@{fn}(expected_surface)")
    return text


def fix_read_ref_elem_compare(text: str) -> str:
    text = text.replace(
        "false -> case elem_type == expected_type of {\n"
        "                            false -> case type_checker_tuple_decompose_helpers@types_equal_surface(elem_type, expected_type) of {",
        "false -> case surface_type_matches_expected(context, elem_type, expected_type) of {\n"
        "                            false -> case type_checker_tuple_decompose_helpers@types_equal_surface(elem_type, expected_surface) of {",
    )
    text = text.replace(
        "false -> case elem_type == expected_type of {\n"
        "                                        false -> type_checker_core@type_check_err",
        "false -> case surface_type_matches_expected(context, elem_type, expected_type) of {\n"
        "                                        false -> type_checker_core@type_check_err",
    )
    return text


def fix_lifetime(text: str) -> str:
    return text.replace(
        'true -> case expected_type == "lifetime" of {\n'
        "                                            true -> type_checker_core@type_check_ok();\n"
        '                                            false -> type_checker_core@type_check_err("E2003", expr.location, concat("fresh_lifetime returns lifetime, got ", expected_type), "sect22.1")',
        "true -> do\n"
        "                                            life_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, \"lifetime\");\n"
        "                                            case type_checker_core@types_equal_type_ids(expected_type, life_out.type_id) or type_checker_core@type_id_is_discard(context, expected_type) of {\n"
        "                                                true -> type_checker_core@type_check_ok();\n"
        '                                                false -> type_checker_core@type_check_err("E2003", expr.location, concat("fresh_lifetime returns lifetime, got ", expected_surface), "sect22.1")\n'
        "                                            }\n"
        "                                        end",
    )


def fix_float_builtins(text: str) -> str:
    text = text.replace(
        "fn check_float_special_const_call(expr: Expr, expected_type: int64) -> TypeCheckResult {",
        "fn check_float_special_const_call(expr: Expr, expected_type: int64, context: TypeContext) -> TypeCheckResult {",
    ).replace(
        "check_float_special_const_call(expr, expected_type);",
        "check_float_special_const_call(expr, expected_type, context);",
    )
    text = text.replace(
        "        true -> case expected_type == ret or type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_discard(context)) of {\n"
        "            true -> type_checker_core@type_check_ok();\n"
        '            false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(concat(expr.name, " returns "), ret), concat(", expected ", expected_type)), "sect6")',
        "        true -> do\n"
        "            ret_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, ret);\n"
        "            case type_checker_core@types_equal_type_ids(expected_type, ret_out.type_id) or type_checker_core@type_id_is_discard(context, expected_type) of {\n"
        "                true -> type_checker_core@type_check_ok();\n"
        '                false -> type_checker_core@type_check_err("E2003", expr.location, concat(concat(concat(expr.name, " returns "), ret), concat(", expected ", expected_type_surface(context, expected_type))), "sect6")\n'
        "            }\n"
        "        end",
    )
    text = text.replace(
        'true -> case expected_type == "bool" or type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_boolean(context)) or type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_discard(context)) of {',
        "true -> case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_boolean(context)) of {",
    )
    text = text.replace(
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat(expr.name, concat(" returns bool, expected ", expected_type)), "sect6")',
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat(expr.name, concat(" returns bool, expected ", expected_type_surface(context, expected_type))), "sect6")',
    )
    text = text.replace(
        "            r: TypeCheckResult <- check_expr(expr.inner, arg_t, context, world);",
        "            r: TypeCheckResult <- check_expr_surface_type(expr.inner, arg_t, context, world);",
    )
    text = text.replace(
        "fn checked_int64_result_type_ok(expected_type: int64) -> bool {\n    expected_type == \"(boolean, int64)\"\n}",
        "fn checked_int64_result_type_ok(context: TypeContext, expected_type: int64) -> bool {\n"
        "    tuple_out: TypeContextParseOutcome <- type_checker_core@context_parse_type(context, \"(boolean, int64)\");\n"
        "    type_checker_core@types_equal_type_ids(expected_type, tuple_out.type_id) or type_checker_core@type_id_is_discard(context, expected_type)\n"
        "}",
    ).replace(
        "case checked_int64_result_type_ok(expected_type) of {",
        "case checked_int64_result_type_ok(context, expected_type) of {",
    ).replace(
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat("checked int64 built-in returns (boolean, int64), got ", expected_type), "common_contract§9");',
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat("checked int64 built-in returns (boolean, int64), got ", expected_type_surface(context, expected_type)), "common_contract§9");',
    )
    return text


def fix_print_builtin_cases(text: str) -> str:
    blocks = [
        ('"boolean" -> type_checker_core@type_check_ok();\n                                                    "atom" -> type_checker_core@type_check_ok();\n                                                    "discard" -> type_checker_core@type_check_ok();',
         "case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_boolean(context)) or type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_atom(context)) of {\n                                                        true -> type_checker_core@type_check_ok();"),
        ('"atom" -> type_checker_core@type_check_ok();\n                                                        "discard" -> type_checker_core@type_check_ok();',
         "case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_atom(context)) of {\n                                                        true -> type_checker_core@type_check_ok();"),
        ('"int64" -> type_checker_core@type_check_ok();\n                                                            "discard" -> type_checker_core@type_check_ok();',
         "case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_int64(context)) of {\n                                                            true -> type_checker_core@type_check_ok();"),
        ('"actor_ref" -> type_checker_core@type_check_ok();\n                                                                    "discard" -> type_checker_core@type_check_ok();',
         "case type_checker_core@type_id_eq_or_discard(context, expected_type, type_checker_core@context_tid_actor_ref(context)) of {\n                                                                    true -> type_checker_core@type_check_ok();"),
    ]
    for old, new in blocks:
        if old in text:
            text = text.replace(
                f"true -> case expected_type of {{\n                                                    {old}",
                f"true -> {new}",
            )
            text = text.replace(
                f"true -> case expected_type of {{\n                                                        {old}",
                f"true -> {new}",
            )
            text = text.replace(
                f"true -> case expected_type of {{\n                                                            {old}",
                f"true -> {new}",
            )
            text = text.replace(
                f"true -> case expected_type of {{\n                                                                    {old}",
                f"true -> {new}",
            )
    # close orphaned case blocks - replace remaining _: string error lines for print builtins
    text = re.sub(
        r'_: string -> type_checker_core@type_check_err\("E2003", expr\.location, concat\("print_bool expects boolean or atom result, got ", expected_type\), "sect6"\)',
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat("print_bool expects boolean or atom result, got ", expected_type_surface(context, expected_type)), "sect6")\n                                                    }',
        text,
    )
    text = re.sub(
        r'_: string -> type_checker_core@type_check_err\("E2003", expr\.location, concat\("print_atom expects atom result, got ", expected_type\), "sect6"\)',
        'false -> type_checker_core@type_check_err("E2003", expr.location, concat("print_atom expects atom result, got ", expected_type_surface(context, expected_type)), "sect6")\n                                                    }',
        text,
    )
    for name, tid in [
        ("atom_bits expects int64 result", "context_tid_int64"),
        ("actor_ref_bits expects int64 result", "context_tid_int64"),
        ("actor_ref_of_word expects actor_ref result", "context_tid_actor_ref"),
    ]:
        text = re.sub(
            rf'_: string -> type_checker_core@type_check_err\("E2003", expr\.location, concat\("{name}, got ", expected_type\), "sect6"\)',
            rf'false -> type_checker_core@type_check_err("E2003", expr.location, concat("{name}, got ", expected_type_surface(context, expected_type)), "sect6")\n                                                            }}',
            text,
        )
    return text


def fix_float32_call_sites(text: str) -> str:
    return text.replace(
        "type_checker_expressions_float32_calls@check_print_float32_call(expr, expected_type, arg_result)",
        "type_checker_expressions_float32_calls@check_print_float32_call(expr, expected_type, context, arg_result)",
    )


def fix_check_expr_string_args(text: str) -> str:
    # check_expr with string-typed variables (not tid helpers)
    string_arg_vars = [
        "operand_type", "region_type", "elem_type", "ref_type", "buf_type",
        "state_t", "arg_type", "num_type", "arg_t", "fn_type", "rhs_type",
        "resolved_param", "second_param", "msg_expected", "r1_type", "r2_type",
        "list_t", "ft", "reply_type",
    ]
    for var in string_arg_vars:
        text = re.sub(
            rf"check_expr\(([^,]+),\s*{var}\s*,\s*context,\s*world\)",
            rf"check_expr_surface_type(\1, {var}, context, world)",
            text,
        )
    return text


def fix_list_helpers(text: str) -> str:
    text = text.replace(
        "fn list_primitive_collectable_context_type(expr: Expr, expected_type: int64, context: TypeContext) -> string {\n    case expr.name == \"empty\" of {\n        true -> expected_type;",
        "fn list_primitive_collectable_context_type(expr: Expr, expected_type: int64, context: TypeContext) -> string {\n    case expr.name == \"empty\" of {\n        true -> expected_type_surface(context, expected_type);",
    )
    text = text.replace(
        "type_checker_lists@types_equal_strip(expected_type, elem_res)",
        "type_checker_lists@types_equal_strip(expected_type_surface(context, expected_type), elem_res)",
    )
    text = text.replace(
        "type_checker_lists@types_equal_strip(expected_type, resolved_return)",
        "type_checker_lists@types_equal_strip(expected_type_surface(context, expected_type), resolved_return)",
    )
    return text


def fix_collections(text: str) -> str:
    p = ROOT / "type_checker_collections.silica"
    t = p.read_text()
    t = t.replace(
        "fn resolve_accumulator_call_formal(expected_type: int64, formal: string) -> string {\n    e: string <- strip_spaces_col(expected_type);",
        "fn resolve_accumulator_call_formal(expected_type: int64, formal: string, context: TypeContext) -> string {\n    e: string <- strip_spaces_col(type_checker_core@type_id_to_surface(context, expected_type));",
    ).replace(
        'false -> replace_assoc_token_in_type(formal, "AccType", expected_type)',
        'false -> replace_assoc_token_in_type(formal, "AccType", type_checker_core@type_id_to_surface(context, expected_type))',
    )
    p.write_text(t)
    text = text.replace(
        "type_checker_collections@resolve_accumulator_call_formal(expected_type, receiver_resolved_return)",
        "type_checker_collections@resolve_accumulator_call_formal(expected_type, receiver_resolved_return, context)",
    )
    text = text.replace(
        "type_checker_collections@resolve_accumulator_call_formal(expected_type, params_inner)",
        "type_checker_collections@resolve_accumulator_call_formal(expected_type, params_inner, context)",
    )
    # collection helpers expecting string bind types
    for fn in [
        "is_collection_trait_type",
        "bind_type_has_collection_runtime_fields",
        "collection_return_accepts_constructor",
        "runtime_record_accepts_constructor_return",
        "find_field_type_in_record",
    ]:
        text = text.replace(f"@{fn}(expected_type,", f"@{fn}(expected_type_surface(context, expected_type),")
        text = text.replace(f"@{fn}(expected_type)", f"@{fn}(expected_type_surface(context, expected_type))")
    text = text.replace(
        "formal_type_accepts_actual(resolved_return, expected_type, world)",
        "formal_type_accepts_actual(resolved_return, expected_type_surface(context, expected_type), world)",
    )
    text = text.replace(
        "formal_type_accepts_actual(expected_type, resolved_return, world)",
        "formal_type_accepts_actual(expected_type_surface(context, expected_type), resolved_return, world)",
    )
    text = text.replace(
        'trim_leading_user_call(expected_type) == "string"',
        'trim_leading_user_call(expected_type_surface(context, expected_type)) == "string"',
    )
    text = text.replace(
        "actual_type_satisfies_trait_expectation(resolved_return, expected_type, world)",
        "actual_type_satisfies_trait_expectation(resolved_return, expected_type_surface(context, expected_type), world)",
    )
    text = text.replace(
        " or expected_type == \"AccType\" of {",
        ' or expected_type_surface(context, expected_type) == "AccType" of {',
    )
    text = text.replace(
        "formal_bind: string <- case type_checker_collections@is_collection_trait_type(expected_type) of {",
        "formal_bind: string <- case type_checker_collections@is_collection_trait_type(expected_type_surface(context, expected_type)) of {",
    )
    text = text.replace(
        "        true -> expected_type;\n        false -> case type_checker_collections@bind_type_has_collection_runtime_fields(expected_type) of {\n            true -> expected_type;",
        "        true -> expected_type_surface(context, expected_type);\n        false -> case type_checker_collections@bind_type_has_collection_runtime_fields(expected_type_surface(context, expected_type)) of {\n            true -> expected_type_surface(context, expected_type);",
    )
    return text


def fix_lists_file(text_lists: str) -> str:
    return text_lists.replace(
        "fn resolve_list_type_from_collectable_generic(elem: string, space: string, expected_type: int64, context: TypeContext) -> (bool, string, string, string) {",
        "fn resolve_list_type_from_collectable_generic(elem: string, space: string, list_context_type: string) -> (bool, string, string, string) {",
    ).replace(
        "        true -> case type_checker_core@types_equal_type_ids(expected_type, type_checker_core@context_tid_discard(context)) of {\n            true -> (false, \"\", \"\", \"\");\n            false -> do\n                exp_surface: string <- type_checker_core@type_id_to_surface(context, expected_type);\n                (ok_e: bool, ee: string, es: string) <- parse_list_type_params(exp_surface);",
        "        true -> case strip_all_spaces_list(list_context_type) == \"discard\" of {\n            true -> (false, \"\", \"\", \"\");\n            false -> do\n                (ok_e: bool, ee: string, es: string) <- parse_list_type_params(list_context_type);",
    )


def fix_error_concat_expected(text: str) -> str:
    # common error messages still concatenating int64 expected_type
    replacements = [
        (', expected ", expected_type)', ', expected ", expected_type_surface(context, expected_type))'),
        (', got ", expected_type)', ', got ", expected_type_surface(context, expected_type))'),
        (', expected ", expected_type), "', ', expected ", expected_type_surface(context, expected_type)), "'),
        ('concat(", expected ", expected_type)', 'concat(", expected ", expected_type_surface(context, expected_type))'),
        ('got ", expected_type), "', 'got ", expected_type_surface(context, expected_type)), "'),
        ('context ", expected_type)', 'context ", expected_type_surface(context, expected_type))'),
        ('type ", expected_type)', 'type ", expected_type_surface(context, expected_type))'),
        ('record type, got ", expected_type)', 'record type, got ", expected_type_surface(context, expected_type))'),
        ('tuple type, got ", expected_type)', 'tuple type, got ", expected_type_surface(context, expected_type))'),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def fix_supervisor_spawn(text: str) -> str:
    if "fn check_supervisor_spawn_result_type(expr: Expr, expected_type: int64, context: TypeContext" not in text:
        text = text.replace(
            "fn check_supervisor_spawn_result_type(expr: Expr, expected_type: int64, builtin_label: string) -> TypeCheckResult {",
            "fn check_supervisor_spawn_result_type(expr: Expr, expected_type: int64, context: TypeContext, builtin_label: string) -> TypeCheckResult {",
        )
    return text


def fix_types_equal_surface_ft(text: str) -> str:
    return text.replace(
        "type_checker_tuple_decompose_helpers@types_equal_surface(ft, expected_type)",
        "type_checker_tuple_decompose_helpers@types_equal_surface(ft, expected_type_surface(context, expected_type))",
    ).replace(
        "type_checker_tuple_decompose_helpers@types_equal_surface(inferred, expected_type)",
        "type_checker_tuple_decompose_helpers@types_equal_surface(inferred, expected_type_surface(context, expected_type))",
    )


def fix_string_calls_remaining(path: Path) -> None:
    t = path.read_text()
    # functions still comparing expected_type as string via char checks
    rewrites = [
        ("fn check_length_bytes_call(expr: Expr, expected_type: int64, arg1_result: TypeCheckResult) -> TypeCheckResult {",
         "fn check_length_bytes_call(expr: Expr, expected_type: int64, context: TypeContext, arg1_result: TypeCheckResult) -> TypeCheckResult {"),
        ("fn check_length_chars_call(expr: Expr, expected_type: int64, arg1_result: TypeCheckResult) -> TypeCheckResult {",
         "fn check_length_chars_call(expr: Expr, expected_type: int64, context: TypeContext, arg1_result: TypeCheckResult) -> TypeCheckResult {"),
    ]
    for old, new in rewrites:
        t = t.replace(old, new)
    # replace is_int64_type_name(expected_type) pattern blocks with type_id helpers - do one generic helper usage
    for fn in [
        "check_length_bytes_call", "check_length_chars_call", "check_concatenate_call",
        "check_substring_call", "check_substring_until_char_call", "check_string_predicate_call",
        "check_read_lines_call", "check_file_exists_call", "check_delete_file_call", "check_append_file_call",
    ]:
        pass
    p.write_text(t)


def main() -> None:
    text = EXPR.read_text()
    text = insert_helpers(text)
    text = fix_arithmetic_block(text)
    text = fix_logical_block(text)
    text = fix_print_and_negate(text)
    text = fix_region_builtin_header(text)
    text = fix_read_ref_elem_compare(text)
    text = fix_lifetime(text)
    text = fix_float_builtins(text)
    text = fix_print_builtin_cases(text)
    text = fix_float32_call_sites(text)
    text = fix_check_expr_string_args(text)
    text = fix_list_helpers(text)
    text = fix_collections(text)
    text = fix_error_concat_expected(text)
    text = fix_supervisor_spawn(text)
    text = fix_types_equal_surface_ft(text)
    EXPR.write_text(text)

    lists = ROOT / "type_checker_lists.silica"
    lists.write_text(fix_lists_file(lists.read_text()))

    print("Applied second pass fixes")


if __name__ == "__main__":
    main()
