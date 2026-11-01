# Silica compiler creation order

Order of data flow through the compiler, from source to executable, with each step's purpose.

## Related Documents

| Document | Purpose |
|----------|---------|
| [src/sir_design_spec.md](src/sir_design_spec.md) | SIR structure, terms, types, primitives |
| [src/sir_optimization_spec.md](src/sir_optimization_spec.md) | Optimization passes and effect-aware rules |
| [src/sir_recursion_strategy.md](src/sir_recursion_strategy.md) | Recursion handling: tail calls, folds, explicit stack |

---

## 1. Lexer

Turn source text into a stream of tokens (keywords, identifiers, literals, operators, punctuation). Handles whitespace and comments. Produces the input the parser consumes.

---

## 2. Parser

Consume the token stream and build an abstract syntax tree (AST) according to the language grammar. Ensures the program is syntactically valid and represents its structure (expressions, statements, declarations).

---

## 3. Type checker

Perform semantic analysis on the AST: resolve names, check types, enforce type rules and scoping. Produces a type-checked (and typically type-annotated) AST used by later passes.

---

## 4. Effect checker

Enforce the effect system: track and propagate effects (e.g. device I/O, concurrency, memory) through expressions, function calls, and bindings. Validate that function effect declarations match their bodies and that operations only run in contexts with the required capabilities.

---

## 5. Intermediate representation (SIR)

Lower the checked AST into SIR (Silica Intermediate Representation), a functional, expression-oriented IR with explicit types and effects. SIR uses terms (`const`, `var`, `let`, `case`, `call`, `tail_call`, `prim`) and is designed for optimization and code generation. See `src/sir_design_spec.md` for the full specification.

---

## 6. Optimization

Apply optimizations to SIR to improve performance without changing program behavior. Optimizations operate on SIR terms (`let`, `case`, `call`, `tail_call`, `prim`). Tail-call handling is done in code generation (emit jump for `tail_call`); no recursion-to-loop pass. LTO is out of scope (linker not implemented).

See [src/sir_optimization_spec.md](src/sir_optimization_spec.md) for the full optimization specification, including pass order, design conclusions, and effect-aware rules. Recursion handling (tail calls, folds, explicit stack): see [src/sir_recursion_strategy.md](src/sir_recursion_strategy.md).

---

## 7. Code generation

Emit target assembly or machine code from the (optimized) SIR. Lowers SIR terms to basic blocks and machine instructions: case to decision tree or jump table, let to assignments, prim to target instructions. Tail calls emit jumps; non-tail recursion uses fold lowering or explicit-stack lowering per [src/sir_recursion_strategy.md](src/sir_recursion_strategy.md). Allocates registers, selects instructions, and handles the target architecture's calling conventions and layout.

---

## 8. Assembler

Convert assembly text into relocatable object files (e.g. `.o`), including machine code, symbols, sections, and relocation information.

---

## 9. Linker

Combine one or more object files and libraries, resolve external references, assign final addresses, and produce the executable (or shared library).
