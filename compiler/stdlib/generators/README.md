# Generators for the storage carriers

Silica has no record update and no type alias. A carrier whose state is a record of twenty or thirty fields
therefore repeats the record's type in every signature and writes every field wherever one changes. The two
storage carriers of transport design §6.8 are kept in a shorter form here, and their `.silica` files in
`compiler/stdlib/` are written from it. The `.silica` files are what the compiler reads and what is committed;
after changing a generator or a template, regenerate and commit both.

| Module | Kept as | Regenerate with |
| --- | --- | --- |
| `store_memory_carrier.silica` | `store_memory_carrier.silica.template` | `python3 record_template.py expand store_memory_carrier.silica.template ../store_memory_carrier.silica` |
| `dangerous_store.silica`, `dangerous_store_backing_carrier.silica` | `gen_backing_carrier.py` | `python3 gen_backing_carrier.py` |

`python3 record_template.py check <template> <module>` exits 0 when the template still expands to the module.

**The template form** (`record_template.py`): the first line names the state's fields once,
`@@FIELDS name: type, ...@@`; `@@ST@@` stands for the record's type; `@@S(base){f=>v;;g=>w}@@` stands for a record
literal in which every field is `base.<field>` except those listed. `record_template.py template` makes a template
from any module of this shape.

**`gen_backing_carrier.py`** holds the backing carrier's text with named placeholders for its record literals
(`OPENING`, `DRAINED`, ...) and prints the carrier's initial-state literal. That literal is also spelled in
`compiler/src/emitter/apple_silicon_mac/transport_pack.silica`, in the spawn text of the `(:backing)` link, because a
program cannot call a dangerous module's `initial`: when a field of the state changes, change the pack's text too.

The trial programs of both carriers are generated as well: `trials/transport_addition/generators/`.
