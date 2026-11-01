# SIR Generator Formalization Specification

## Document Purpose

This document formalizes the design for the GAB tool and sir_generator component established in Clarification and Discussion modes. It serves as the authoritative specification for Generation Mode.

**Related Documents**

| Document | Purpose |
|----------|---------|
| [sir_design_spec.md](sir_design_spec.md) | SIR structure, types, terms, primitives |
| [sir_optimization_spec.md](sir_optimization_spec.md) | Optimization passes |
| [type_checker/](../src/type_checker/) | Reference directory pattern |

---

## 1. Product Overview

### 1.1 Deliverables

| # | Deliverable | Format | Scope |
|---|-------------|--------|-------|
| 1 | GAB prompt/agent | JSON-LD | Interactive guide for building/extending sir_generator |
| 2 | sir_generator Silica modules | .silica | Only sir_generator; no main.silica or Makefile changes |

### 1.2 Out of Scope

- Changes to `main.silica` (call site)
- Changes to `src/Makefile` or build system
- Effect checker integration (deferred)

---

## 2. GAB Tool Specification

### 2.1 Type

GAB prompt/agent (Option A): A JSON-LD file that, when loaded, guides the user interactively through building and extending the sir_generator. The agent does not generate code in one shot; it assists the user step-by-step.

### 2.2 Responsibilities

1. **Initial setup**: Guide creation of `sir_generator/` directory structure (core, declarations/, terms/, types/, patterns/)
2. **Capability addition**: When user adds AST capabilities (arithmetic, structs, lambdas, etc.), guide creation of new files and wiring into dispatchers
3. **Reference material**: Point to sir_design_spec.md, sir_optimization_spec.md for SIR semantics
4. **Pattern adherence**: Enforce type_checker directory pattern but with short filenames (no sir_generator_ prefix)

### 2.3 Reference Documents

The GAB tool MUST reference and instruct the user to consult:

- `AArch64/silica-compiler/sir_design_spec.md` — SIR grammar, types, terms, primitives
- `AArch64/silica-compiler/sir_optimization_spec.md` — Effect-aware optimization rules
- `AArch64/silica-compiler/src/type_checker/` — Directory pattern and module structure

---

## 3. sir_generator Specification

### 3.1 Invocation Contract

- **Input**: `Program` (parser AST). Type checking is a precondition: if type checking fails, sir_generator is never called.
- **Output**: SIR held internally as data structures (SIRModule, SIRFunction, SIRTerm per sir_design_spec §2). Text `.sir` format is for debugging/export only; the pipeline uses the in-memory representation.
- **Dependencies**: lexer_core, parser_ast, type_checker_core (as needed for type lookup)

### 3.2 Directory Structure

```
sir_generator/
├── core.silica
├── Makefile
├── declarations/
│   ├── functions.silica
│   └── (structs.silica, enums.silica, ... when capabilities added)
├── terms/
│   ├── terms.silica           # dispatcher
│   ├── literals.silica
│   ├── identifiers.silica
│   └── (arithmetic.silica, calls.silica, ... when capabilities added)
├── types/
│   └── types.silica
└── patterns/
    └── patterns.silica        # (when case/pattern AST exists)
```

**Naming**: Filenames do NOT use `sir_generator_` prefix; directory provides context.

### 3.3 Output (Internal Representation)

SIR is held in memory as SIRModule containing ListSIRFunction. Optional text serialization (for debugging) would use short names per sir_design_spec §8:

- `core.sir` — module header, type/struct/enum decls if any
- `declarations.sir` — function declarations

### 3.4 Extensibility Rule

New capability files are added when AST supports them. Examples:

- `terms/arithmetic.silica` — when Expr has arithmetic operators
- `terms/structs.silica` — when AST has struct construction/projection
- `terms/typed_vars.silica` — when AST has let with explicit type
- `terms/lambdas.silica` — when AST has function literals
- `terms/case.silica` — when AST has case expressions
- `declarations/structs.silica` — when AST has struct declarations

Each dispatcher (e.g. `terms/terms.silica`) switches on AST node kind and delegates to capability-specific modules.

---

## 4. Minimal AST Mapping (Current State)

### 4.1 AST Structures (parser_ast)

| AST Node | Fields | Notes |
|----------|--------|-------|
| Program | declarations: ListDeclaration, location | Root |
| Declaration | tag, name, return_type_name, return_type_location, location | tag 0 = function |
| ListDeclaration | is_nil, head, tail | Linked list |
| Expr | kind, value, name, location, inner | kind 0=literal, 1=ident, 2=paren |
| TypeName | name, location | — |

### 4.2 Known Limitation: Declaration Has No Body

**Current state**: `Declaration` has no `body` field. The parser produces `fn foo ( ) -> int64 { }` with empty braces; the body is not parsed.

**Required behavior**: For empty-body functions, sir_generator MUST emit a placeholder body term that satisfies SIR validation (body type must match return type). Specification:

- For `return_type_name == "int64"`: emit `const int64 0`
- For `return_type_name == "unit"` or future unit: emit `const unit ()`
- For other known types: document default in types.silica or emit a conservative placeholder

**Future**: When parser adds body parsing, Declaration will have a body field (Expr); sir_generator will then emit the lowered term instead of a placeholder.

### 4.3 Minimal Expr → SIRTerm Mapping

| Expr.kind | SIR Term | Notes |
|-----------|----------|-------|
| 0 | const(SIRType, value) | value from Expr.value; type from literal or context |
| 1 | var(name) | name from Expr.name; format as %name |
| 2 | (recurse) | emit term for Expr.inner |
| -1 | (invalid) | dummy_expr; must not reach sir_generator |

### 4.4 Declaration → SIRFunction (Minimal)

- **name**: `module.function_name` (module default: `main` until module support exists)
- **params**: Empty (current parser has no parameters)
- **return_type**: From Declaration.return_type_name
- **effects**: `[]` (effects deferred)
- **body**: Placeholder per §4.2 until body exists in AST

### 4.5 Program → SIRModule

- Traverse ListDeclaration (while not is_nil, process head, recurse on tail)
- For each Declaration with tag 0: emit SIRFunction to declarations.sir
- Emit module header to core.sir (e.g. `module main`)

---

## 5. Validation Rules

### 5.1 Preconditions

- sir_generator is only called when type checking has succeeded
- AST must not contain dummy nodes in traversed paths (tag ≥ 0 for Declaration, kind ≥ 0 for Expr in body)

### 5.2 SIR Output Validation

- Every function body term must have type equal to declared return type
- Variable names in SIR must use `%` prefix (e.g. `%x`, `%tmp_1`)
- Output must conform to sir_design_spec §8 (lexical conventions, module syntax, term syntax)

### 5.3 Type Resolution

- For literals (kind 0): type inferred from literal (e.g. integer → int64)
- For identifiers (kind 1): type from type checker context (type checker adds symbols; sir_generator may need TypeContext or equivalent to resolve)
- For return types: use Declaration.return_type_name directly (already validated by type checker)

---

## 6. Formalization Analysis

### 6.1 Logic Check

| Check | Result |
|-------|--------|
| Contradictory requirements | None identified |
| Impossible constraints | None |
| Missing prerequisites | Declaration has no body; handled by placeholder rule (§4.2) |
| Circular dependencies | None |
| Undefined references | All referenced (parser_ast, lexer_core, type_checker_core) exist |
| Type mismatches | Placeholder body type must match return type — specified |
| AALang compliance | GAB tool is JSON-LD; sir_generator is Silica — compliant |

### 6.2 Gap: Type Context for Identifiers

**Gap**: For Expr kind 1 (identifier), sir_generator needs the identifier's type to emit `var(%name)` with correct SIR type. The type checker has TypeContext and lookup_symbol, but sir_generator receives only the AST. Type checker does not attach types to AST nodes.

**Resolution**: Either (a) sir_generator receives TypeContext (or type-annotated AST) from the caller, or (b) sir_generator re-runs type lookup during traversal. Recommendation: **Caller passes TypeContext** to sir_generator so it can resolve identifier types without re-type-checking. This must be reflected in the tool's API design.

### 6.3 Consistency

- Output format (text .sir) is consistent with sir_design_spec §8
- Directory structure is consistent with type_checker pattern
- Extensibility rule is consistent with incremental AST growth

---

## 7. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-12 | Initial formalization |

---

Created using AALang and Gab
