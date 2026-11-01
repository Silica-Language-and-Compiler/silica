# Sequence Blocks in Silica (Updated)

This document updates the original `do ... end` tutorial to the new, explicit-keyword design:

- `` — introduces an expression block that sequences steps
- `` — marks the result boundary of the block (what value the block returns)
- `` — monadic unit: lifts an effect-free expression into a computation with no effects
- `` — monadic bind: names the result of a computation (effectful or pure)

The semantics are unchanged: a sequence block runs steps in order and returns a value you can bind or return.

---

## Function Bodies vs. Sequence Blocks

Function bodies use `{ }` and can contain statements directly. You don’t need `sequence ... end` inside them—the braces already form a block. Both `{ }` and `sequence ... end`:

- Accept a sequence of statements (bindings and expressions)
- Execute them in order
- Return a value

**Where they appear differs:**

- `` — Used for function and lambda bodies. The grammar expects a body there.
- `` — Used when you need that same sequencing in an **expression position** (e.g., the RHS of a case branch or a binding).

**Rule of thumb:** Use `sequence ... end` when you need to run effectful operations (declare effects with `sequence proc[ε]`) or when you need to run several steps in order and use the result of one step in the next *in expression position*.

---

## Why Sequence Blocks Are a Good Idea

Sequence blocks let you write a recipe of steps where each step can use results from earlier ones, without deep nesting. They also make effect tracking explicit and reviewable.

**Benefits:**

- **Readable flow**: steps run top-to-bottom.
- **Named intermediates**: bind results to names (`x: int64 <- compute()`), reuse later.
- **Effect tracking**: the compiler aggregates effects across binds.
- **Explicit result boundary**: `produces` shows exactly what the block returns.
- **Explicit purity at the boundary**: `pure` asserts the returned expression introduces no new effects.

**Why explicit purity at the boundary is a good idea**

- **Prevents accidental effect leakage**: Reviewers (and the compiler) can see that no new effects are introduced at the point the value is produced. If someone later changes the final expression to call an effectful operation, it fails fast.
- **Makes effect auditing easier**: All effects must appear *above* `produces`; the `pure` line is a clear "effect horizon." This is especially helpful in code review and security audits.
- **Stabilizes refactors**: You can refactor internal steps freely without changing the block’s outward effect profile, as long as the `pure` line remains effect-free.
- **LLM reliability**: The fixed shape `sequence … produces pure <value> end` reduces generation mistakes (e.g., accidentally returning an effectful call as the final value).
- **Spec clarity**: It aligns surface syntax with the monadic unit (`return`/η), making the computation/value boundary explicit.

**Block shape:**

- **Effect-free sequence** (no effectful operations):
```silica
sequence
    -- steps (binds and expressions)
produces
    pure <value>
end
```

- **Effectful sequence** (uses functions requiring effects):
```silica
sequence proc[ε]
    -- steps (binds and expressions)
produces
    pure <value>
end
```

---

## Effect Declaration Rules

When a sequence block uses functions that require effects, those effects **must** be declared immediately after the `sequence` keyword (e.g. `sequence proc[DeviceIO]`).

**Rules:**

1. **Sequence-level declaration required:** All functions requiring effects must be used inside `sequence ... produces ... end` blocks. Effectful operations may not appear outside sequence blocks.

2. **Effects declared on the sequence:** If a sequence uses effectful operations, declare the required effects right after `sequence` (e.g. `sequence proc[DeviceIO]` or `sequence proc[concurrency, device_io]`).

3. **No overlap with function effects:** An effect declared for a sequence **cannot** be declared for the entire function. If the same effect appears in both places, the parser raises an error.

4. **Function effects do not apply to sequences:** Function-wide effect declarations (e.g. `proc[DeviceIO]` in the return type) do **not** apply to any sequence block. Each sequence must declare its own effects. A sequence cannot rely on the enclosing function’s effect signature.

5. **No sequence needed when pure:** A function does **not** need a `sequence ... produces ... end` block if it uses no functions requiring effects. Pure functions use ordinary expressions and braces.

6. **Lists and `mem`:** Constructing or growing a **`List[T]`** (literals, **`empty`**, **`prepend`**, **`length`** on allocated lists, etc.) **requires** a **`mem(<space>)`** effect on the **`sequence`** block. Use **`sequence proc[mem(<space>)]`** … **`produces`** **`pure`** … **`end`**. **`<space>`** matches the memory policy for the region backing the list (see **`tutorials_and_howtos/memory_region_types.md`**). Add **`device_io`** when the block also **prints** or performs other I/O: **`sequence proc[mem(normal), device_io]`**. **Do** **not** **attach** **`proc[…]`** **to** **named** **function** **return** **types**; **wrap** **list** **access** **in** **`sequence`** **inside** **the** **function** (**`list_int64_recursive_sum.silica`**). See **`design_documents/list_implementation_design.md`** §7 and **`trials/list_addition/`** (e.g. **`list_int64_two_primaries_shared_suffix.silica`**).

---

## Good Examples

### Multiple Steps, Each Depends on the Last

```silica
fn parse_line(content: string, start: int64) -> string {
    case start >= length_chars(content) of {
        true -> "";
        false -> sequence proc[DeviceIO]
            line: string <- substring_until_char(content, start, '\n');
            trimmed: string <- trim_leading(line);
        produces
            pure trimmed
        end
    }
}
```

**Why this is good:** You need `line` to compute `trimmed`, and the block produces `trimmed`. Effects are declared on the sequence; the function’s effect type is inferred from its body.

---

### Multiple Steps in a Function Body

```silica
fn read_and_process(path: string) -> int64 {
    sequence proc[DeviceIO]
        content: string <- read_lines(path);
        trimmed: string <- trim_leading(content);
    produces
        pure length_chars(trimmed)
    end
}
```

**Why this is good:** Read, transform, then return a value; effects are declared on the sequence and aggregated across steps.

---

### Actor: Spawn, Send, Then Return

```silica
fn start_echo_actor() -> actor_ref {
    sequence proc[concurrency, device_io]
        echo_ref: actor_ref <- spawn(
            EchoState { received: 0 },
            fn(msg: Response, state: EchoState) -> EchoState {
                sequence proc[device_io]
                    print_string("Received: ");
                produces
                    pure EchoState { received: state.received + 1 }
                end
            }
        );
        send(echo_ref, Response { result: 42 });
    produces
        pure echo_ref
    end
}
```

**Why this is good:** You need the `actor_ref` from `spawn` to `send`, then return it. Effects are declared on each sequence; the returned value is explicitly pure.

---

### Sequence Block Returns a Value You Use

```silica
-- The sequence block returns int64; that value is used
fn get_actor_and_log() -> int64 {
    sequence proc[concurrency, device_io]
        ref: actor_ref <- spawn(State {}, fn(msg: Msg, s: State) -> State { s });
        send(ref, Msg {});
    produces
        pure length_chars("started")
    end
}

-- Single effectful operation still requires a sequence block
fn fire_and_forget(ref: actor_ref) -> atom {
    sequence proc[concurrency]
        send(ref, Msg {});
    produces
        pure ()
    end
}

-- The sequence block's return value is bound and passed on
fn process() -> string {
    result: int64 <- sequence proc[DeviceIO]
        content: string <- read_lines("config.txt");
    produces
        pure length_chars(content)
    end;
    concat("Length: ", int_to_string(result))
}
```

---

## Bad Examples (Non-Examples)

### Single Expression, No Intermediate Steps

```silica
fn add(x: int64, y: int64) -> int64 {
    x + y
}

fn main() -> int64 {
    42
}
```

**Why not use **``**:** There’s nothing to sequence.

---

### Actor: Spawn and Return (Single Expression — Invalid)

```silica
fn start_actor() -> actor_ref {
    spawn(InitialState {}, fn(msg: Msg, state: InitialState) -> InitialState { state })  -- ERROR: spawn is effectful, must be in sequence
}
```

**Why this is bad:** Even though it is a single expression, `spawn` requires effects and must appear inside `sequence proc[concurrency] ... end`. The handler `fn(msg: Ping, state: Counter) -> Counter { ... }` is pure and correctly needs no sequence.

---

### Redundant Sequence Around a Single Expression

```silica
fn redundant() -> int64 {
    sequence
        produces
            pure 42
    end
}
```

**Why this is bad:** Adds noise without benefit. The function uses no effectful operations, so no sequence block is needed.

---

### Effect Declared on Both Function and Sequence (Parser Error)

```silica
fn read_file(path: string) -> string proc[DeviceIO] {  -- ERROR: DeviceIO on function
    sequence proc[DeviceIO]                            -- and DeviceIO on sequence
        content: string <- read_lines(path);
    produces
        pure content
    end
}
```

**Why this is bad:** An effect declared for a sequence cannot also be declared for the entire function. Parser error.

---

### Effectful Operation Outside Sequence Block

```silica
fn bad_io() -> string {
    content: string <- read_lines("file.txt");  -- ERROR: effectful call outside sequence
    content
}

fn fire_and_forget_bad(ref: actor_ref) -> atom {
    send(ref, Msg {})  -- ERROR: effectful call outside sequence
}
```

**Why this is bad:** All functions requiring effects must be used inside `sequence ... produces ... end` blocks.

---

### Relying on Function Effects for a Sequence

```silica
fn wrong_approach(path: string) -> int64 proc[DeviceIO] {
    sequence  -- ERROR: sequence uses read_lines but does not declare proc[DeviceIO]
        content: string <- read_lines(path);
    produces
        pure length_chars(content)
    end
}
```

**Why this is bad:** Function-wide effect declarations do not apply to sequences. Each sequence must declare its own effects.

---

## Summary

| Situation                               | Use `sequence ... end`? | Declare effects on sequence? |
| --------------------------------------- | ----------------------- | ----------------------------- |
| Multiple steps with bindings (effectful) | Yes                     | Yes (`sequence proc[ε]`)       |
| Case/if branch with several steps       | Yes                     | Yes, if effectful              |
| Actor: spawn then send then return      | Yes                     | Yes (`sequence proc[ε]`)       |
| Single effectful operation              | Yes                     | Yes                           |
| Pure function (no effectful calls)      | No                      | N/A                           |
| Single pure expression                  | No                      | N/A                           |

---

## Appendix: Monadic View (Effect-Indexed Kleisli Composition)

Silica’s sequence blocks are surface syntax for Kleisli composition in an effect-indexed monad.

- Computations have type `proc[ε] A`.
- **Bind:** `x <- m` sequences computations and accumulates effects.
- **Unit:** `pure a : proc[∅] A` injects a value with no effects.
- **Sequence (effectful):**

```text
sequence proc[ε]
    x1 <- m1;
    x2 <- m2(x1);
produces
    pure e
end

≡ m1 >>= (λx1. m2(x1) >>= (λx2. return e))
```

- The resulting effect set ε is declared on the sequence and is the union of effects across all bound computations.

---

## Style & Linting (Recommended)

- Require exactly one `produces` per `sequence` block.
- Require the block to end with `pure <expr>`.
- Forbid effectful operations under `pure`.
- Discourage `sequence` blocks with a single step.
- Require `sequence proc[ε]` when the block uses any effectful operations.
- Forbid declaring the same effect on both a function and a sequence inside it.

