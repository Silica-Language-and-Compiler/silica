# train_trial_generator

Generates paired Silica trials for LLM training: for every success program placed in
its `trials/<area>_addition/` directory (with `.ascomp` and `.scout` goldens) there is a
failure twin with the **same file stem** in `trials/error_enforcement_addition/`
(with `.golden_fail`). Every failure is the success program with exactly one
deliberate mistake, and its first line names the diagnostic it triggers:
`// expected failure E2018: binding 'x' has no type annotation`.

Nothing is installed unless it has been proven against the real compiler:

1. `build_manifest.py` — builds candidate cases from seeded templates
   (`numeric.py`, `data.py`, `control.py`, `systems.py`); `driver.py` attaches
   generic single-edit mutations (`common.py`) and assigns stems.
2. `pipeline.py` — compiles each success candidate alone, then in a scratch copy of
   its trial directory; assembles, links, runs it and requires stdout + exit status to
   equal the generator's own expectation. Compiles each failure candidate in isolation
   exactly as the error-enforcement makefile does and requires the intended error
   code; up to five candidate mistakes are tried per pair. Emits the golden files.
3. `validate.sh` — copies each affected trial directory into scratch together with the
   shared makefile scaffolding and runs the real `make integrate` there.
4. `install.py` — copies the verified files into `trials/`; refuses to overwrite
   any file whose name does not start with `train_`.

Since 2026-10-10 (actor_memory_budget_plan.md item M) every pair is in the supervisor-actor shape:
`pipeline.py` runs `shape_stage.py` on the pairs it keeps (`M_SHAPE=0` turns it off), and
`python3 shape_stage.py --installed OUT [area,...]` followed by `python3 install.py OUT` reshapes the
pairs already installed. See programmer_tools/trial_shape_m/README.md.

## Usage

```sh
cd programmer_tools/train_trial_generator
python3 build_manifest.py 1.0 manifest.json            # scale 1.0 ≈ 4,800 candidates
python3 pipeline.py manifest.json report.json OUT       # OUT/<area>/... + OUT/error_enforcement_addition/...
bash validate.sh OUT int8_addition string_addition ...  # real make integrate per area
python3 install.py OUT --dry && python3 install.py OUT
```

Environment: `SILICA_ROOT` (repo root; default derived from this directory),
`SILICA_COMPILER` (default `binaries/silica-compiler`), `SILICA_GEN_WORK` (scratch
area; default under the system temp dir), `GEN_SEED` and `STEM_OFFSET` for a
supplementary batch whose numbering must not collide (the installed set used
`GEN_SEED=20260908` and, for the second batch, `GEN_SEED=777 STEM_OFFSET=5000`).
`build_manifest.py` takes an optional comma-separated area list as its third
argument.

## Areas deliberately excluded

`ordered_data_structures` (by request), `traits_addition` (adding units there makes
the seed restart between units and `shape_main` then fails to link), `ffi_addition`,
`warning_enforcement_addition`, `cpu_discovery_and_spawn_pinning`,
`deep_frame_spill_addition`. See
`compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md`
for the compiler defects the generator had to work around.
