# `emitter/linux_x86_64/ladder/` — the bring-up ladder for the x86-64 backend

Fifteen small programs copied from the ESP32-S3 port's early apps
(`emitter/ESP32-S3_raw/board/apps/silica_00_return42` … `silica_14_wbt_map`), each with the
`expected.scout` the macOS compiler produced for the same source (`<stdout><exit status>\n`, the trial
harness form, with a process-fatal report line folded to `[silica] fault at <PTR>` /
`[silica] abort: <reason> at <PTR>` by `trials/normalize_fatal_reports.awk`). They are the **order of work for the debug phase**: each step adds one emitter piece,
and a step is done when its program prints exactly its `expected.scout` on nix.

| Step | App | Exercises |
| --- | --- | --- |
| 1 | `silica_00_return42` | module prelude, `.set SVR_AREA` frame header, prologue/epilogue, `main` returning through rax |
| 2 | `silica_01_arith`, `silica_02_calls` | lets, int64 arithmetic (idiv paths), calls with arguments in rdi…, results in rdi, recursion, parameter shadows into frame slots |
| 3 | `silica_03_case_bool` | compares (`cmp` + `setcc`/`jcc`), and/or short circuit (real pushes), nested case |
| 4 | `silica_04_print`, `silica_05_int64_wide` | `L_pi_helper`/`L_ps_helper` (write syscall), 64-bit multiply/divide |
| 5 | `silica_06_strings` | string runtime (mmap arena, concat, length, substring) |
| 6 | `silica_07_recursion_depth`, `silica_08_stack_guard` | frame size under deep recursion on the platform stack; the fault path (`08` expects the fatal fault report `[silica] fault at 0x...` and status 70) |
| 7 | `silica_09_lists` … `silica_11_regions` | list cells, records/tuples (frame regions off `rbp - SVR_AREA`), regions/refs/bufs |
| 8 | `silica_12_floats` | xmm arithmetic, F16C float16, ucomisd conditions, the digit-exact print helpers |
| 9 | `silica_13_checked` | checked int64 (overflow flag), tuple returns |
| 10 | `silica_14_wbt_map` | the stdlib map compiled with the app (`extra_sources.txt`) |

After the ladder: the actor runtime (`__silica_runtime.sams`: spawn, mailboxes, futex, the
sigaltstack growth handler), supervisors, FFI — then `trials/` suite by suite as the plan's Phase 3
table lists.

## Running a step on nix

Historical note: the cross-compiler link `binaries/silica-compiler-linux_x86_64` was removed on 2026-10-21; nix now builds and runs its own native compiler (silica-999974-linux-x86_64), so the steps below are the original bring-up method.

The Mac compiles (cross compiler `binaries/silica-compiler-linux_x86_64`, built with
`make -C src build TARGET=linux_x86_64 SILICA_COMPILER=binaries/silica-compiler INSTALL_SELFHOST=0`
after `make clean`), nix assembles, links and runs. For one app:

```sh
# Mac: compile into a scratch directory (the compiler reads silica.config from cwd)
app=silica_04_print
tmp=$(mktemp -d); cd "$tmp"
: > silica.config
# stdlib modules the app needs, in dependency order (silica_14_wbt_map only)
while IFS= read -r rel; do [ -n "$rel" ] && cp "/Volumes/2T/silica/compiler/$rel" . && basename "$rel" >> silica.config; done \
  < "/Volumes/2T/silica/compiler/src/emitter/linux_x86_64/ladder/$app/extra_sources.txt" 2>/dev/null
cp "/Volumes/2T/silica/compiler/src/emitter/linux_x86_64/ladder/$app/"*.silica . && ls *.silica >> silica.config
/Volumes/2T/silica/binaries/silica-compiler-linux_x86_64
rsync -a --include='*.sams' --exclude='*' ./ lee@nix.local:/tmp/ladder/$app/
rsync -a /Volumes/2T/silica/compiler/src/runtime_asm/linux_x86_64/ lee@nix.local:/tmp/ladder/rt/
rsync -a "/Volumes/2T/silica/compiler/src/emitter/linux_x86_64/ladder/$app/expected.scout" lee@nix.local:/tmp/ladder/$app/
rsync -a /Volumes/2T/silica/trials/normalize_fatal_reports.awk lee@nix.local:/tmp/ladder/

# nix: assemble (GNU as through cc), link without PIE (data tables hold absolute .quad addresses), run, diff
ssh lee@nix.local "cd /tmp/ladder/$app && for f in *.sams; do cc -c -x assembler \$f -o \${f%.sams}.o || exit 1; done \
  && cc -no-pie -rdynamic -o prog *.o ../rt/silica_rt_shim.s ../rt/deviceio_link_thunks.s -lpthread \
  && { ./prog > out.txt 2>&1; echo \$? >> out.txt; } \
  ; awk -f ../normalize_fatal_reports.awk out.txt > out.norm && awk -f ../normalize_fatal_reports.awk expected.scout | diff out.norm - && echo PASS"
```

`__silica_runtime.sams` is emitted whenever a program defines `main` (the pid registry init runs at
every entry point), so the actor runtime text is part of the very first step's link; a step that
fails inside it is debugged with `objdump -d -M intel` and `gdb` on nix (install with
`sudo apt install gdb` when available). Compare the emitted text with the AArch64 tree's output for
the same source when a sequence looks wrong: the emitter logic is identical, only the shared layer's
expansion differs.

`silica_08_stack_guard` recurses without bound on the platform stack (main is not an actor):
the expected result is the fatal fault report of spec §15.4.5.5, `[silica] fault at 0x<pc> in
<symbol>+0x<offset>  addr=...  actor=0x0...` on stderr and exit status 70, from the runtime's
SIGSEGV handler on its alternate stack. The handler must not turn the fault into a stack-growth attempt
outside an actor reservation, and a bare status 139 means the handler was not installed. The report's
addresses differ by run, so the comparison above folds the line to `[silica] fault at <PTR>` (see
[design_documents/runtime_failure_reporting.md](../../../../design_documents/runtime_failure_reporting.md)).
A runtime abort prints `[silica] abort: <reason> at 0x<pc>...` and exits 71.
