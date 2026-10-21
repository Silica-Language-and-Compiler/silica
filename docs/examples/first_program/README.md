# First program: a supervisor, one actor, and one message

The first program from *Learn to Program* (`docs/learn-programming.md`, Chapter 3).

## Files

- `main.silica` — starts the supervisor (the elephant mother), sends the actor one message carrying two numbers, and then waits so the program stays alive.
- `adder.silica` — the actor's behaviour: it adds the two numbers and prints the total.

`main.silica` also contains the supervisor's `init` function, which lists the one child the supervisor gives birth to, and the FailureReporter that `main` starts and registers before anything else (spec §15.4.13.4; the compiler rejects a start before registration with E2236). The reporter writes each failure report to stderr and ends the program with status 70 if the supervisor itself fails.

The program also uses the standard-library `Supervisor` trait, `compiler/stdlib/Supervisor.silica`. List it in `silica.config` beside these two files (the trials in `trials/supervisors_addition` show one way to do that).

## Build and run (macOS on Apple silicon)

Work in a scratch copy, because the compiler writes its outputs next to the sources:

```sh
mkdir /tmp/first_program && cp main.silica adder.silica ../../../compiler/stdlib/Supervisor.silica /tmp/first_program
cd /tmp/first_program
printf 'Supervisor.silica\nadder.silica\nmain.silica\n' > silica.config
/path/to/silica/binaries/silica-compiler          # writes one .sams per unit and __silica_runtime.sams
for f in Supervisor adder main __silica_runtime; do clang -c -x assembler $f.sams -o $f.o; done
clang main.o adder.o Supervisor.o __silica_runtime.o -o first_program -Wl,-e,main
./first_program
```

On Linux, compile with the platform's compiler (`binaries/silica-compiler-linux_x86_64` or
`binaries/silica-compiler-linux_aarch64`) and link as `trials/linux_host.mk` does, without `-Wl,-e,main`:

```sh
for f in Supervisor adder main __silica_runtime; do cc -c -x assembler $f.sams -o $f.o; done
cc main.o adder.o Supervisor.o __silica_runtime.o -o first_program -no-pie -rdynamic -lpthread
```

`-e main` is for dyld, which calls the entry point as a function; on Linux the kernel starts the process at
the entry point with `argc` on top of the stack and no return address, so `main` would run 8 bytes off the
System V stack alignment and fault in the first libc routine that needs it (`docs/examples/idle_actor_capacity/README.md`
has the details), and its `ret` would have nowhere to go.

The published `binaries/silica-compiler` (`silica-999949-macos-applesilicon` on 2026-10-16) compiles it and prints `5`. `main` registers the reporter before any start (error E2236 otherwise) and the reporter calls `cast_exit`, so a compiler older than those rules does not compile it.

## Expected output

```
5
```

After printing `5` the program waits. Type `exit` and press Enter and it ends with exit code `0` (the line counts as `cast_exit(0)`, so a later `cast_exit` returns `false`). Closing its input does not end it: `wait_for_exit` goes on waiting for `cast_exit` or an `exit` line (spec §15.1.2.5). An `exit` line sent at once (`echo exit | ./first_program`) can end the program before the adder has printed, so it prints nothing; the `5` is printed when the `exit` arrives a moment later.

## Verified

Compiled and run with `binaries/silica-compiler` on 2026-09-18 (macOS, Apple silicon) through the trial `integrate` flow with a `.scout` golden of `5` followed by the exit code `0`. Compiled and run again on 2026-09-19 with `binaries/silica-compiler` (`silica-999972`): prints `5`, exits `0` after `exit`.

Since 2026-10-11 `main` registers a FailureReporter first. That version was compiled and run with the E2236 test compiler: prints `5`, exits `0` after `exit`. Re-verified on 2026-10-16 with a private build of the current tree: the steps above print `5`, and `exit` sent two seconds after the start ends it with exit code `0`; with its input closed (`< /dev/null`) it prints `5` and keeps waiting.
