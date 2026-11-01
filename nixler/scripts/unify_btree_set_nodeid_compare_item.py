#!/usr/bin/env python3
"""Unify NodeIDBTreeSet tree value shape with compare_item last (Phase 0.4 step 1)."""

from pathlib import Path
import re

PATH = Path(__file__).resolve().parents[1] / "src/standard_data_structures/btree_set_nodeid.silica"

NODES = "List[{ id: int64, key_count: int64, is_leaf: int64, keys: List[int64, mem(normal)], children: List[int64, mem(normal)] }, mem(normal)]"
CMP = "compare_item: fn(int64, int64) -> :less | :equal | :greater"

OLD_HELPERS = """fn key_equal(left: int64, right: int64) -> int64 {
    case left == right of {
        true -> 1;
        false -> 0
    }
}

fn key_less(left: int64, right: int64) -> int64 {
    case left < right of {
        true -> 1;
        false -> 0
    }
}"""

NEW_HELPERS = """fn compare_int64_atom(left: int64, right: int64) -> :less | :equal | :greater {
    case left < right of {
        true -> :less;
        false -> case left == right of {
            true -> :equal;
            false -> :greater
        }
    }
}

fn cmp_is_equal(cmp: fn(int64, int64) -> :less | :equal | :greater, left: int64, right: int64) -> int64 {
    case cmp(left, right) of {
        :equal -> 1;
        _: atom -> 0
    }
}

fn cmp_is_less(cmp: fn(int64, int64) -> :less | :equal | :greater, left: int64, right: int64) -> int64 {
    case cmp(left, right) of {
        :less -> 1;
        _: atom -> 0
    }
}

fn cmp_is_less_or_equal(cmp: fn(int64, int64) -> :less | :equal | :greater, left: int64, right: int64) -> int64 {
    case cmp(left, right) of {
        :less -> 1;
        :equal -> 1;
        _: atom -> 0
    }
}

fn cmp_is_greater(cmp: fn(int64, int64) -> :less | :equal | :greater, left: int64, right: int64) -> int64 {
    case cmp(left, right) of {
        :greater -> 1;
        _: atom -> 0
    }
}"""


def tree_block(indent: str) -> str:
    return (
        f"{indent}root_id: int64,\n"
        f"{indent}node_count: int64,\n"
        f"{indent}order: int64,\n"
        f"{indent}nodes: {NODES},\n"
        f"{indent}{CMP}"
    )


def reorder_tree_types(content: str) -> str:
    # compare_item-first tree blocks (any indent 4/8/12)
    pattern = re.compile(
        r"(?P<indent>[ \t]{4,12})compare_item: fn\(int64, int64\) -> :less \| :equal \| :greater,\n"
        r"(?P=indent)root_id: int64,\n"
        r"(?P=indent)node_count: int64,\n"
        r"(?P=indent)order: int64,\n"
        r"(?P=indent)nodes: "
        + re.escape(NODES),
    )

    def repl(m: re.Match[str]) -> str:
        return tree_block(m.group("indent"))

    return pattern.sub(repl, content)


def reorder_tree_literals(content: str) -> str:
    pattern = re.compile(
        r"(?P<indent>[ \t]{8,12})compare_item: (?P<cmp>compare_int64_atom|tree(?:_saved|_with_new_root)?\.compare_item|item_functions\.compare_item),\n"
        r"(?P=indent)root_id: (?P<root>[^\n]+),\n"
        r"(?P=indent)node_count: (?P<nc>[^\n]+),\n"
        r"(?P=indent)order: (?P<ord>[^\n]+),\n"
        r"(?P=indent)nodes: (?P<nodes>[^\n]+)",
    )

    def repl(m: re.Match[str]) -> str:
        ind = m.group("indent")
        return (
            f"{ind}root_id: {m.group('root')},\n"
            f"{ind}node_count: {m.group('nc')},\n"
            f"{ind}order: {m.group('ord')},\n"
            f"{ind}nodes: {m.group('nodes')},\n"
            f"{ind}compare_item: {m.group('cmp')}"
        )

    return pattern.sub(repl, content)


def main() -> None:
    content = PATH.read_text()
    content = content.replace(OLD_HELPERS, NEW_HELPERS)

    # empty/0 without compare_item in tree yet
    head_empty0 = f"""fn empty[int64, mem(normal)]() -> {{
        root_id: int64,
        node_count: int64,
        order: int64,
        nodes: {NODES}
}} {{
    sequence proc[mem(normal)]
        nodes: {NODES} <-
            empty[{{ id: int64, key_count: int64, is_leaf: int64, keys: List[int64, mem(normal)], children: List[int64, mem(normal)] }}, mem(normal)]();
        tree: {{
            root_id: int64,
            node_count: int64,
            order: int64,
            nodes: {NODES}
        }} <- {{
            root_id: -1,
            node_count: 0,
            order: order(),
            nodes: nodes
        }}
    produces
        pure tree
    end
}}"""

    new_empty0 = f"""fn empty[int64, mem(normal)]() -> {{
{tree_block("        ")}
}} {{
    sequence proc[mem(normal)]
        nodes: {NODES} <-
            empty[{{ id: int64, key_count: int64, is_leaf: int64, keys: List[int64, mem(normal)], children: List[int64, mem(normal)] }}, mem(normal)]();
        tree: {{
{tree_block("            ")}
        }} <- {{
            root_id: -1,
            node_count: 0,
            order: order(),
            nodes: nodes,
            compare_item: compare_int64_atom
        }}
    produces
        pure tree
    end
}}"""

    if head_empty0 in content:
        content = content.replace(head_empty0, new_empty0)

    # Add compare_item last to bare tree return types and parameter tree blocks.
    bare = f""") -> {{
        root_id: int64,
        node_count: int64,
        order: int64,
        nodes: {NODES}
}}"""
    bare_cmp = f""") -> {{
{tree_block("        ")}
}}"""
    content = content.replace(bare, bare_cmp)

    bare4 = f""") -> {{
    root_id: int64,
    node_count: int64,
    order: int64,
    nodes: {NODES}
}}"""
    bare4_cmp = f""") -> {{
{tree_block("    ")}
}}"""
    content = content.replace(bare4, bare4_cmp)

    param8 = f"""    tree: {{
        root_id: int64,
        node_count: int64,
        order: int64,
        nodes: {NODES}
    }},"""
    param8_cmp = f"""    tree: {{
{tree_block("        ")}
    }},"""
    content = content.replace(param8, param8_cmp)

    # empty/1 -> empty_record + wrapper
    if "fn empty_record" not in content:
        content = content.replace("fn empty(item_functions:", "fn empty_record(item_functions:", 1)
        insert_at = content.index("fn list_int64_length")
        wrapper = f"""
fn empty(item_functions: {{ compare_item: fn(int64, int64) -> :less | :equal | :greater }}) -> {{
{tree_block("    ")}
}} {{
    empty_record(item_functions)
}}

"""
        content = content[:insert_at] + wrapper + content[insert_at:]

    # empty_record literal: add compare_item from item_functions at end
    content = content.replace(
        """        } <- {
            compare_item: item_functions.compare_item,
            root_id: -1,
            node_count: 0,
            order: order(),
            nodes: nodes
        }""",
        """        } <- {
            root_id: -1,
            node_count: 0,
            order: order(),
            nodes: nodes,
            compare_item: item_functions.compare_item
        }""",
    )

    # insert_root_leaf and other tree literals missing compare_item
    content = content.replace(
        """        } <- {
            root_id: 0,
            node_count: 1,
            order: order(),
            nodes: nodes
        };""",
        """        } <- {
            root_id: 0,
            node_count: 1,
            order: order(),
            nodes: nodes,
            compare_item: compare_int64_atom
        };""",
    )

    content = reorder_tree_types(content)
    content = reorder_tree_literals(content)

    # Preserve compare_item across updates using source tree field.
    content = content.replace(
        "compare_item: compare_int64_atom,\n            root_id: tree.root_id",
        "root_id: tree.root_id",
    )
    content = content.replace(
        "root_id: tree.root_id,\n            node_count: tree.node_count + 1,\n            order: tree.order,\n            nodes: nodes_final\n        }",
        "root_id: tree.root_id,\n            node_count: tree.node_count + 1,\n            order: tree.order,\n            nodes: nodes_final,\n            compare_item: tree.compare_item\n        }",
    )
    content = content.replace(
        "root_id: tree_saved.root_id,\n            node_count: tree_saved.node_count,\n            order: tree_saved.order,\n            nodes: new_nodes\n        }",
        "root_id: tree_saved.root_id,\n            node_count: tree_saved.node_count,\n            order: tree_saved.order,\n            nodes: new_nodes,\n            compare_item: tree_saved.compare_item\n        }",
    )
    content = content.replace(
        "root_id: new_root.id,\n            node_count: tree.node_count + 1,\n            order: tree.order,\n            nodes: nodes_with_new_root\n        };",
        "root_id: new_root.id,\n            node_count: tree.node_count + 1,\n            order: tree.order,\n            nodes: nodes_with_new_root,\n            compare_item: tree.compare_item\n        };",
    )

    PATH.write_text(content)
    print(f"Updated {PATH}")


if __name__ == "__main__":
    main()
