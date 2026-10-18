# idle_actor_capacity

How many actors that do nothing can this machine hold? `main.silica` starts idle actors without end, in
batches of 1,000, and prints the running total after each batch. The last total printed is the answer.

**It is meant to exhaust the machine.** On the hosted targets every actor is still its own operating-system
thread (until ROADMAP chunk 2's carrier threads), so the program uses threads, memory and address space
until something gives out:

- the operating system refuses another thread;
- a stack reservation fails, and the spawner ends with `(:explicit, :stack_reserve_failed)`;
- memory and swap run out, and the host's out-of-memory handling decides what to stop. That may be this
  program, or something else on the machine.

Close other work before running it, watch Activity Monitor, and stop it with Ctrl-C or by typing `exit`
and Return. It is not a trial and is not run by any harness.

## The two knobs

- `batch_size()`: how many actors each message starts (1,000).
- `reserve_bytes()`: each idle actor's stack reservation (64 KB). With `0`, every actor reserves the
  machine's memory plus swap of address space, so address space runs out first, after a few thousand
  actors, and the number says little about memory. A small reserve measures what idle actors really cost.

## Build (macOS on Apple silicon)

From this directory, with the repository's published compiler:

```sh
echo main.silica > silica.config
../../../binaries/silica-compiler
clang -c -x assembler main.sams -o main.o
clang -c -x assembler __silica_runtime.sams -o __silica_runtime.o
clang main.o __silica_runtime.o -o idle_actor_capacity -Wl,-e,main
```

The compile, assemble and link steps were checked on 2026-10-08 with `silica-999955` (an 83 KB executable).
Since 2026-10-11 `main` registers a FailureReporter before it starts the spawner (spec §15.4.13.4, error
E2236 otherwise); the reporter writes each failure report to stderr, as the runtime did before. That version
was compiled, assembled and linked again on 2026-10-16 with a private build of the current tree (a 106 KB
executable), and run for two seconds on macOS before being stopped: it printed `1000 idle actors`,
`2000 idle actors`, and so on, reaching `411000 idle actors` in those two seconds, with no failure. The
compile writes its outputs next to `main.silica`, so build in a scratch copy of this directory rather than in
the repository tree.

## Output

One line per batch, the running total:

```
1000 idle actors
2000 idle actors
3000 idle actors
```

## Run

```sh
./idle_actor_capacity
```
