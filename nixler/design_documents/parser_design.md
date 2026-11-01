# Silica Parser Design: Constraint Propagation

## Document Purpose

This document defines the principles, properties, and architecture for the Silica parser. The parser uses **constraint propagation** rather than conventional recursive descent, LL, LR, or PEG parsing. This design enables incremental capability addition with strong modularity.

**Related Documents**

| Document | Purpose |
|----------|---------|
| [silica-compiler-code-organization.md](silica-compiler-code-organization.md) | Overall compiler structure |
| [silica-specification.md](silica-specification.md) | Silica language syntax and semantics |
| [sir_generator_formalization_spec.md](../sir_generator_formalization_spec.md) | Downstream SIR generator contract |

---

## 1. Core Principles

### 1.1 Constraint Propagation (Principle 1)

**Parsing is constraint satisfaction, not grammar-driven recognition.**

- Each token starts with a set of possible **roles** (e.g., fn_keyword, fn_name, type_name, integer_literal).
- Grammar rules are expressed as **constraints** between adjacent tokens.
- Parsing = repeatedly applying constraints until each token has exactly one role (or a contradiction is found).
- Structure emerges from the final role sequence; no explicit recursive descent.

**Properties:**
- Constraints are local: each rule only references adjacent token pairs.
- Constraints are independent: adding a new rule does not require modifying existing rules.
- The propagation engine is generic: it does not need to know grammar specifics.

### 1.2 One File Per Capability (Principle 2)

**Each language capability has exactly one dedicated file.**

- A capability is a coherent syntactic construct (e.g., function declarations, integer literals, case expressions).
- All constraints, role definitions, and structure extraction for that capability live in a single file.
- Adding a new capability = adding one new file + one line in the constraint registry.
- No capability spans multiple files; no file spans multiple capabilities.

**Properties:**
- Easy navigation: locate all code for a feature in one place.
- Minimal merge conflicts: new capabilities rarely touch existing files.
- Incremental development: capabilities can be added in any order.
- Testability: each capability can be tested in isolation.

### 1.3 Immutability (Principle 3)

**All parser data structures are immutable.**

- Constraint propagation returns new structures; it never mutates in place.
- Token slots, constraint sets, and the final AST are all immutable values.
- Aligns with Silica's functional design and enables safe concurrency.

### 1.4 Implementation Language: Silica (Principle 4)

**The parser is implemented in Silica.**

- Uses Silica's structs, linked lists, recursion, and case expressions.
- No arrays or mutable buffers; uses `List[T, mem(normal)]` of records (tokens, slots, constraints) and `List[int64, mem(normal)]` for role sets. Silica has no named struct or list-of-X types, so the `ListToken`, `ListInt`, `TokenSlot` and `Constraint` names in this document are shorthand for inline record and `List[...]` types.
- All types are concrete; no generics.

---

## 2. Architecture Overview

### 2.1 Pipeline Stages

```
Lexer (ListToken) → Constraint Parser → Role-Assigned Slots → Structure Extraction → Program (AST)
```

1. **Lexer**: Produces `ListToken` (tokens with kind, lexeme, location).
2. **Slot Initialization**: Convert each token to a `TokenSlot` with initial possible roles.
3. **Constraint Propagation**: Apply constraints until fixed point or contradiction.
4. **Structure Extraction**: Build AST (or sparse matrix) from the final role sequence.
5. **Output**: `Program` compatible with type checker and SIR generator.

### 2.2 Data Flow

```
ListToken
    ↓ (initialize_roles)
ListTokenSlot
    ↓ (propagate_until_fixed)
ListTokenSlot (each slot has exactly one role)
    ↓ (extract_structure)
Program
```

---

## 3. Data Structures

### 3.1 TokenSlot

A token with a set of possible syntactic roles.

```silica
struct TokenSlot {
    token: Token,           // from lexer (kind, lexeme, location)
    possible_roles: ListInt // list of role codes still possible
}

struct ListTokenSlot {
    is_nil: bool,
    head: TokenSlot,
    tail: ListTokenSlot
}
```

### 3.2 Constraint

Bidirectional rules: **forward**—when token A has role X, token B (immediately following) must have role in [Y, Z, ...]; **backward**—when token B has role X, token A (immediately preceding) must have role in [Y, Z, ...]. Empty list means no constraint in that direction.

```silica
struct Constraint {
    trigger_role: int64,       // when a token is fixed to this role
    next_token_roles: ListInt, // allowed roles for the following token (empty = no forward constraint)
    prev_token_roles: ListInt, // allowed roles for the preceding token (empty = no backward constraint)
    constraint_id: int64       // for debugging and error reporting
}

struct ListConstraint {
    is_nil: bool,
    head: Constraint,
    tail: ListConstraint
}
```

### 3.3 Role Codes

Implementation status (2026-10-16): `propagate_until_fixed` first converts the constraint list into two role-indexed tables (`build_next_table`, `build_prev_table`, indexed by trigger role) and propagates through those, so a role lookup is a table index rather than a scan of the constraint list. Roles are integer codes. Each capability defines its own role namespace. Examples:

| Role Code | Role Name | Capability |
|-----------|-----------|------------|
| 1 | fn_keyword | fn_decl |
| 2 | fn_name | fn_decl |
| 3 | left_paren | fn_decl |
| 4 | right_paren | fn_decl |
| 5 | right_arrow | fn_decl |
| 6 | type_name | fn_decl |
| 7 | left_brace | fn_decl |
| 8 | right_brace | fn_decl |
| 9 | body_expr | fn_decl, expr_literal |
| 10 | integer_literal | expr_literal |
| 11 | identifier | expr_literal |

---

## 4. Algorithm

### 4.1 Initialization

For each token, set `possible_roles` based on token kind:

- `fn_keyword` → [fn_keyword]
- `identifier` → [fn_name, type_name, identifier, ...] (union of roles from all capabilities)
- `integer_literal` → [integer_literal]
- etc.

Each capability contributes its role initializations via `initial_roles_for_token(kind) -> ListInt`.

### 4.2 Propagation

```
propagate_pass(slots, constraints):
  for each adjacent pair (slot_i, slot_{i+1}):
    # Forward: when slot_i has one role, narrow slot_{i+1}
    if slot_i has exactly one role R:
      allowed = merge next_token_roles from constraints where trigger_role = R
      if allowed non-empty:
        slot_{i+1} = TokenSlot{token, intersect(slot_{i+1}.possible_roles, allowed)}
    # Backward: when slot_{i+1} has one role, narrow slot_i
    if slot_{i+1} has exactly one role R:
      allowed = merge prev_token_roles from constraints where trigger_role = R
      if allowed non-empty:
        slot_i = TokenSlot{token, intersect(slot_i.possible_roles, allowed)}
  return (new_slots, changed)

propagate_until_fixed(slots, constraints):
  (new_slots, changed) = propagate_pass(slots, constraints)
  if changed: propagate_until_fixed(new_slots, constraints)
  else: return new_slots
```

Propagation is recursive and immutable: each pass builds a new `ListTokenSlot`. Bidirectional constraints enable stronger propagation (e.g., right_paren must be preceded by left_paren).

### 4.3 Success and Failure

- **Success**: Every slot has exactly one role. Proceed to structure extraction.
- **Failure**: Any slot has zero roles (contradiction). Report parse error with location from the token.

---

## 5. Directory Structure and One File Per Capability

### 5.1 Parser Directory Layout

```
parser/
├── constraint_core.silica         # Shared: slots, constraints, role tables, propagation engine
├── constraint_runner.silica       # Shared: parse_program, all_constraints registry, orchestration
├── constraint_extract.silica      # Shared: structure extraction entry (slots to program)
├── constraint_extract_*.silica    # Extraction passes: decls, params, slots, expr, expr_bindings,
│                                  #   expr_lits, lambda_lift, hof_wrap, validate
├── parser_core, parser_ast, parser_tuples, parser_runner, instantiated_fn_name, parse_in_actor
│
├── capabilities/                  # One file per capability (19 today)
│   ├── capability_fn_decl.silica      # fn name ( params ) -> type proc[...] { body }
│   ├── capability_expr_literal.silica # literals and identifiers
│   ├── capability_case.silica         # case ... of { ... }
│   ├── capability_list.silica, capability_sequence.silica, capability_trait.silica,
│   │   capability_actors.silica, capability_foreign.silica, capability_memory_region.silica,
│   │   capability_module.silica, capability_effect_decl.silica, capability_bind.silica,
│   │   capability_tuple_decompose.silica, capability_supervisor_phases.silica, ...
```

Implementation status (2026-10-16): the layout above is the shipped one. There is no `capability_struct`
or `capability_if` file: Silica has no named struct declarations (records are inline types) and
conditionals are `case` expressions. Structure extraction is not a per-capability
`extract_contribution` function; it lives in the shared `constraint_extract_*` passes, which read the
final role sequence.

### 5.2 Capability File Contract

Each capability file MUST:

1. **Export `constraints() -> ListConstraint`**: All constraints for this capability.
2. **Export `initial_roles(token_kind: int64) -> ListInt`**: Roles this capability allows for the given token kind. Returns empty list if this capability does not apply.
3. **Export `extract_contribution(slots: ListTokenSlot, start_index: int64) -> (ASTFragment, int64)`**: Optional in the design. Not used in the implementation (2026-10-16): capabilities export `constraints/0`, `initial_roles/1` and their `role_*` codes; extraction is done by the shared `constraint_extract_*` passes.

Each capability file MUST NOT:

- Depend on another capability's internals.
- Modify shared state.
- Define constraints that reference roles from other capabilities (except shared roles like identifier, type_name).

### 5.3 Constraint Registry

The runner aggregates constraints from all capabilities:

```silica
fn all_constraints() -> ListConstraint {
    base: ListConstraint <- capability_fn_decl@constraints();
    with_expr: ListConstraint <- append_constraints(base, capability_expr_literal@constraints());
    with_case: ListConstraint <- append_constraints(with_expr, capability_case@constraints());
    // Add one line per new capability
    with_case
}
```

### 5.4 Adding a New Capability

1. Create `capabilities/capability_<name>.silica`.
2. Implement `constraints()`, `initial_roles()`, and optionally `extract_contribution()`.
3. Add one line to `all_constraints()` in `constraint_runner.silica`.
4. Add one line to merge `initial_roles` in the role initialization (union per token kind).

---

## 6. Initial Capability: fn main(){ 42 }

### 6.1 Scope

- Function declaration: `fn` identifier `(` `)` `->` type_name `{` expression `}`
- Expression: integer literal or identifier
- Single top-level declaration

### 6.2 Required Capability Files

| File | Responsibility |
|------|----------------|
| `capability_fn_decl.silica` | fn, name, params (empty), return type, braces |
| `capability_expr_literal.silica` | integer literal, identifier as expression |

### 6.3 Example Constraints (capability_fn_decl)

- fn_keyword → next must be fn_name
- fn_name → next must be left_paren
- left_paren → next must be right_paren (empty params)
- right_paren → next must be right_arrow
- right_arrow → next must be type_name
- type_name → next must be left_brace
- left_brace → next must be body_expr or right_brace
- body_expr → next must be right_brace (single expr)

### 6.4 Example Constraints (capability_expr_literal)

- integer_literal (as body_expr) → next must be right_brace
- identifier (as body_expr) → next must be right_brace

---

## 7. Properties Summary

| Property | Description |
|----------|-------------|
| **Modularity** | One file per capability; no cross-file capability logic |
| **Extensibility** | Add capability = add file + one registry line |
| **Immutability** | All data structures immutable; propagation returns new values |
| **Locality** | Constraints reference only adjacent token pairs |
| **Independence** | Constraints do not depend on each other |
| **Testability** | Each capability testable in isolation |
| **Incremental** | Capabilities can be added in any order |
| **Silica-native** | Uses structs, linked lists, recursion; no arrays required |

---

## 8. Error Reporting

- **Contradiction**: When a slot's possible_roles becomes empty, report parse error at that token's location.
- **Ambiguity**: If propagation reaches fixed point but any slot has >1 role, report ambiguity error (or apply disambiguation rules).
- **Incomplete**: If EOF reached before a complete declaration, report "unexpected end of file" at last token.

Error format follows `silica-specification.md` §1.6: structured message with location, error code, spec section reference.

---

## 9. Future Considerations

### 9.1 Bidirectional Constraints (Implemented)

Constraints support "previous token" rules via `prev_token_roles` for stronger propagation (e.g., right_paren must be preceded by left_paren or body_expr). See §3.2 and §4.2.

### 9.2 Sparse Matrix Output

Structure extraction can emit a sparse matrix (parent/child indices) instead of a tree, if desired for downstream phases.

### 9.3 Disambiguation

When multiple roles remain, use precedence, associativity, or context to resolve. Each capability can export disambiguation rules.

---

## 10. Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-15 | Initial design: constraint propagation, one file per capability |
| 1.1 | 2026-10-16 | Layout, capability contract and data-structure notes aligned with the implementation |
