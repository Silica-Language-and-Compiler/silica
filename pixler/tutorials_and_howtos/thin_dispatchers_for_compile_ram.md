```
# Thin dispatchers when compiling uses too much RAM
```

> **Note.** Splitting an application into many compilation units is a work-around for the compiler's memory use, not the language's model: a Silica application is one compilation unit. See [APPLICATION_IS_ONE_COMPILATION_UNIT.md](../design_documents/APPLICATION_IS_ONE_COMPILATION_UNIT.md).

You can already split a recursive walk across leaf modules and keep `use` acyclic by passing callbacks (see [open_recursion_callbacks.md](./open_recursion_callbacks.md)). Compiling can still fail on the **facade**: a short file that `use`s every specialist at once.

This how-to is for that case. It is an extra cut in the module graph, not a replacement for smaller files, leaf-to-root `silica.config` order, or process-per-unit reclaim ([compiling_with_less_ram.md](./compiling_with_less_ram.md)).

---

## Symptom

All of the following usually hold:

1. The leaf modules compile.
2. The facade is small — often a kind `case` and a few helpers.
3. Compiling the facade is killed or exhausts host RAM.
4. That facade `use`s many specialists whose **exported** functions have large structural types (inline records, lists, and callbacks written out in full).

The failing work item is one compilation unit. Reclaim between units does not shrink it: every `use` on that file is paid in the same process.

---



## Why a short facade can still be expensive

Compiling a unit holds two things at once:

1. **That unit’s own functions** — including any callback types written in the source.
2. **Every exported signature** from each module it `use`s (the imported interface).

A facade that `use`s ten specialists loads ten interfaces. If each specialist exports several functions that repeat the same huge callback types, you pay those types many times in one compilation. File length is a weak signal; the `use` list and the size of those exports dominate.

```text
  facade.silica          (dozens of lines)
       │
       ├── use leaf_a     ← fat interface
       ├── use leaf_b     ← fat interface
       ├── use leaf_c     ← fat interface
       └── use …          ← all of them in one process
```

Open recursion keeps leaves from `use`ing the facade. It does **not** stop the facade from loading every leaf interface.

---



## The pattern

Keep the facade as the switchboard: it owns the recursive entry point and passes **local** function values as callbacks.

Do **not** have the facade `use` the leaves.

Insert **two or three thin dispatchers** between the facade and the leaves. Each dispatcher `use`s one group of specialists and exports one (or a few) functions. The facade `use`s only the dispatchers.

```text
                    ┌────────────┐
                    │   facade   │  owns walk / eval; passes local callbacks
                    └─────┬──────┘
           uses only the  │
           dispatchers    │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
   dispatch_direct  dispatch_blocks  dispatch_embeds
          │               │               │
          ▼               ▼               ▼
     small leaves    block leaves    embed leaves
```

Compiling a dispatcher pays for **one group** of leaf interfaces. Compiling the facade pays for **two or three thin exports**, not every leaf export together.

---



## What stays on the facade

These must remain in the same module as the recursive entry point:

- The entry point itself (`walk`, `eval`, `check`, …) and any surface wrapper that only parses a type string and then calls the entry point.
- Any function you pass **as a value** into a leaf. A callback must be a **local** function. A qualified reference (`module@fn`) is not a valid argument.
- Arms that only recurse on a child through the entry point (for example unwrapping a grouping node).
- Routing: which dispatcher handles this kind.

If a local callback’s **body** would `use` a fat leaf, do not put that `use` on the facade. Forward the call through a dispatcher that already `use`s that leaf.

---



## How to group work

Aim for two or three dispatchers, not one per leaf.


| Dispatcher | What to put there                                                                       | Typical `use`s                 |
| ---------- | --------------------------------------------------------------------------------------- | ------------------------------ |
| **Direct** | Kinds that do not take callbacks: literals, names, trivial errors, the default “ok” arm | Small helpers and small leaves |
| **Open A** | One family of recursive specialists                                                     | That family’s leaf modules     |
| **Open B** | The other family                                                                        | The remaining recursive leaves |


Rules of thumb:

- Keep the two **largest** leaf interfaces out of the same dispatcher.
- Do not put a fat callback parameter on a dispatcher that never forwards it. Direct should not take `walk_child` if none of its kinds recurse.
- A kind that needs a helper from a fat leaf (for example a name test that lives next to a large data walker) either moves into that fat dispatcher, or you copy a tiny local helper into Direct so Direct stays small.
- If compiling a dispatcher still fails, split **that** dispatcher the same way. Do not fold it back into the facade.

---



## Implementation steps

1. **Confirm the failing unit is the facade.** Leaves already have artifacts; the batch dies on the switchboard file.
2. **List every** `use` **and every kind arm.** Mark which arms need callbacks and which leaf each arm calls.
3. **Partition into two or three groups** using the table above. Write the grouping down before you edit.
4. **Add dispatcher modules.** Copy parameter and return types from the facade **exactly**. Structural types must match; do not invent named aliases.
5. **Move each kind arm into exactly one dispatcher.** The dispatcher `case`s on kind and calls its leaves. Unused kinds in that dispatcher can return the same default the facade used.
6. **Slim the facade** `use` **list** to helpers plus the dispatchers. Route with a kind `case`, or with small predicates (`is_block_kind`) that take only `int64` — those predicates do not load leaf interfaces.
7. **Pass local functions as callbacks.** From the facade: `dispatch_blocks@walk_blocks(node, walk, walk_caption_cb)`. Do not pass `walk_table@walk_node`.
8. **Forward fat work out of local callbacks.** If `walk_caption_cb` must call a table specialist, its body calls `dispatch_embeds@…`, not the leaf.
9. **Put new modules in** `silica.config` **in dependency order** (leaves, then dispatchers, then facade, then `main`). Regenerating a topo-sorted list is enough if your build already does that.
10. **Compile again.** If a dispatcher fails, split it. If the facade still fails, a dispatcher is re-exporting too much — cut that export list down to the one function the facade calls.

---



## Worked example: walking a report tree

A reporting app walks a node tree. Kinds:

- `0` text, `1` heading, `7` page break — no child walk
- `2` section, `5` list — recurse into children
- `3` table, `4` chart, `6` embed — recurse into captions / cells

Types are shortened here. In a real app the node, environment, and callback types are large inline records; that is exactly why one fat `use` list hurts.

### Before: one facade `use`s every leaf

```silica
// report_walk.silica
use walk_text;
use walk_heading;
use walk_section;
use walk_table;
use walk_chart;
use walk_list;
use walk_embed;
use walk_break;

export walk/1;

fn walk(node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool {
    case node.kind of {
        0 -> walk_text@walk_node(node);
        1 -> walk_heading@walk_node(node);
        2 -> walk_section@walk_node(node, walk);
        3 -> walk_table@walk_node(node, walk);
        4 -> walk_chart@walk_node(node, walk);
        5 -> walk_list@walk_node(node, walk);
        6 -> walk_embed@walk_node(node, walk);
        7 -> walk_break@walk_node(node);
        _: int64 -> true
    }
}
```

Leaves that recurse take `walk` as a callback and do **not** `use report_walk`. That part is already correct. Compiling `report_walk.silica` still loads every leaf interface in one process.

### After: three thin dispatchers

**Direct** — no callbacks, small leaves only:

```silica
// walk_dispatch_direct.silica
use walk_text;
use walk_heading;
use walk_break;

export walk_direct/1;

fn walk_direct(node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool {
    case node.kind of {
        0 -> walk_text@walk_node(node);
        1 -> walk_heading@walk_node(node);
        7 -> walk_break@walk_node(node);
        _: int64 -> true
    }
}
```

**Blocks** — section and list; one callback:

```silica
// walk_dispatch_blocks.silica
use walk_section;
use walk_list;

export walk_blocks/2;

fn walk_blocks(
    node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none },
    walk_child: fn({ kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool
) -> bool {
    case node.kind of {
        2 -> walk_section@walk_node(node, walk_child);
        5 -> walk_list@walk_node(node, walk_child);
        _: int64 -> true
    }
}
```

**Embeds** — table, chart, embed; one callback:

```silica
// walk_dispatch_embeds.silica
use walk_table;
use walk_chart;
use walk_embed;

export walk_embeds/2;

fn walk_embeds(
    node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none },
    walk_child: fn({ kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool
) -> bool {
    case node.kind of {
        3 -> walk_table@walk_node(node, walk_child);
        4 -> walk_chart@walk_node(node, walk_child);
        6 -> walk_embed@walk_node(node, walk_child);
        _: int64 -> true
    }
}
```

**Facade** — local `walk` is still the callback; it `use`s only the dispatchers:

```silica
// report_walk.silica
use walk_dispatch_direct;
use walk_dispatch_blocks;
use walk_dispatch_embeds;

export walk/1;

fn is_block_kind(k: int64) -> bool {
    case k of {
        2 -> true;
        5 -> true;
        _: int64 -> false
    }
}

fn is_embed_kind(k: int64) -> bool {
    case k of {
        3 -> true;
        4 -> true;
        6 -> true;
        _: int64 -> false
    }
}

fn walk(node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool {
    case is_block_kind(node.kind) of {
        true -> walk_dispatch_blocks@walk_blocks(node, walk);
        false -> case is_embed_kind(node.kind) of {
            true -> walk_dispatch_embeds@walk_embeds(node, walk);
            false -> walk_dispatch_direct@walk_direct(node)
        }
    }
}
```

`is_block_kind` / `is_embed_kind` take `int64` only. They do not load table or section interfaces.

`silica.config` order (dependencies first):

```text
walk_text.silica
walk_heading.silica
walk_break.silica
walk_section.silica
walk_list.silica
walk_table.silica
walk_chart.silica
walk_embed.silica
walk_dispatch_direct.silica
walk_dispatch_blocks.silica
walk_dispatch_embeds.silica
report_walk.silica
main.silica
```



### Local callback that must not `use` a leaf

Suppose tables call back into a caption helper that you must pass as a function value. That helper stays on the facade; its body forwards to the embeds dispatcher:

```silica
fn walk_caption_cb(node: { kind: int64, inner: { kind: int64, inner: rec, next: rec } | :none, next: { kind: int64, inner: rec, next: rec } | :none }) -> bool {
    walk_dispatch_embeds@walk_caption(node, walk)
}
```

Do not write `walk_table@walk_caption` as the argument you pass into a leaf. Define `walk_caption_cb` in the facade and pass `walk_caption_cb`.

---



## What this does not replace

- **Oversized leaf files** still need to be split. A dispatcher that `use`s one giant leaf will fail the same way the facade did.
- **Leaf-to-root batching and process-per-unit reclaim** still bound RAM **between** units. Thin dispatchers bound RAM **inside** the switchboard unit.
- **Open recursion** is still how leaves recurse without `use`ing the facade. Dispatchers take the same callbacks and pass them through.

---



## Checklist

**Do**

- Keep the recursive entry point and every passed-as-value callback on the facade.
- Insert two or three dispatchers so no single compilation `use`s every fat leaf.
- Export one function per dispatcher when you can; do not re-export a leaf’s whole API.
- Copy structural types from the existing facade; keep dialect and field spellings consistent.
- Split a dispatcher again if compiling *it* fails.

**Don’t**

- Move a passed-as-value callback into another module and then write `other@fn` at the call site.
- Put Direct and a 90K-interface leaf in the same dispatcher “to have fewer files.”
- Give every dispatcher every callback “for symmetry.”
- Concatenate the dispatchers back into the facade after a successful split.

---



## Related reading

- [compiling_with_less_ram.md](./compiling_with_less_ram.md) — compilation units, leaf-to-root order, reclaim, splitting large files
- [open_recursion_callbacks.md](./open_recursion_callbacks.md) — passing the recursive entry point as a callback so leaves never `use` the facade

