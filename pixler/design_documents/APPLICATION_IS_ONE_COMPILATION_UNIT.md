# An application is one compilation unit

**Read this before designing anything in Silica: language features, runtime behaviour, libraries, traits,
diagnostics, build tooling or trials.** Stated by Lee, the project owner, on 2026-09-19.

## The intent

A Silica application is **one compilation unit**. Everything the application is made of is compiled together, as
one program:

- the application's own `.silica` files;
- every library it uses, including the standard library (`Supervisor`, the data structures, and the rest) and any
  wrapper library such as the Fifi foreign-function wrappers. Libraries are `.silica` source that is compiled in with
  the application. They are not separately compiled binary modules.

Whole-program facts are therefore facts of the application, decided once, over all of it:

- **Atoms.** There is one atom table per application. An atom has one identity everywhere in the application, in
  every file, message, actor state and `case` pattern. The specification already says so: "The atom table is
  program-wide" (silica-specification.md, the "One table per program (normative)" paragraph, near line 3043).
- **Uniqueness rules.** "At most one" rules hold across the whole application: one realized placement trait, one
  placement actor, one owner of a reserved registered name, one definition of each exported function name.
- **Checking.** Type, effect, trait and registry checks can see the whole application. A rule that needs the whole
  program is checked over the whole program.

## What happens today is a work-around

Today (2026-10-16) the compiler cannot hold a whole application in memory, so a build is split into many compilation units:

- `silica.config` lists one unit per `.silica` file;
- each unit is compiled in its own process, and the compiler exits with status 75 between units to give the memory
  back (process-per-unit reclaim);
- units see each other through `.iface` interface files;
- each unit is emitted to its own `.sams`, and the results are linked.

This exists **only** to keep the compiler's memory down. It is not part of the language, and nothing may rely on
it. The specification's description of a batch as "the ordered list of compilation units; each compilation unit is
one `.silica` file" (near line 11696) describes the current implementation, not the language's model.

Where the split build cannot behave like one unit, that is a defect of the work-around, not intended behaviour.
The known case was atom numbering: atoms were numbered per unit, so the same atom could compare unequal across
files. **Implementation status (2026-10-16):** fixed for atoms. The build keeps one atom table in `silica.atoms`
(one lexeme per line, in index order, the fixed runtime prefix first) that every unit reads and extends, and record
shapes are likewise numbered once per build in `silica.shapes`; the runtime module is written once, after the last
unit, from the complete table (`main_emit.silica`, `main_lists.silica`). The cross-unit atom trials
`trials/modules_addition/sd3_cross_unit_atoms.silica` and `sd3_cross_unit_atoms_registered_name.silica` pass
(`.sout` equals `.scout`). The shared tables are the temporary reconciliation of rule 3 below; the work-around
itself (one unit per file, exit 75 between units, `.iface` files) is still how the compiler builds, and the compiler
is still not able to compile an application as one unit.

## Rules for designers

1. **Design for the one-unit model.** Specify every feature as if the whole application, libraries included, is
   compiled at once. Never make a feature's meaning depend on how files are split into units.
2. **Do not design around the work-around.** Do not introduce per-file or per-unit semantics: per-unit atom tables,
   per-unit registries, rules that hold "within a file", or anything that only works because units are compiled
   separately.
3. **Say what the work-around must preserve.** When a design relies on a whole-program fact (atom identity,
   uniqueness, a reserved name), state the one-unit rule first. Then, separately and marked as temporary, state what
   the split build must do meanwhile to keep that rule: for example an application-wide atom table the units share,
   with predefined atoms at fixed indices, or a link-time check for a second definition.
4. **Libraries are source.** Design libraries as `.silica` source compiled into the application. Do not assume a
   separately compiled library format, a stable binary interface between separately built modules, or dynamic loading
   of Silica code.
5. **Treat compile memory as the thing to fix.** When a design needs whole-program information that the split build
   makes expensive, the answer is to reduce and manage the compiler's memory, not to change the language to fit the
   work-around.

## The way back

The goal is to reduce and manage the compiler's memory until a whole application compiles as one unit. At that point
the work-around, its `.iface` files, its process-per-unit reclaim and its per-unit atom numbering go away, and nothing
in the language or the libraries has to change.

Related: [compiling_with_less_ram.md](../tutorials_and_howtos/compiling_with_less_ram.md) and
[thin_dispatchers_for_compile_ram.md](../tutorials_and_howtos/thin_dispatchers_for_compile_ram.md) describe how to
live with the work-around today.
