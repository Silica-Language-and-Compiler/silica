# memory_use_reports

RAM use of each compiler build, kept so it can be tracked over time and runs can be compared.

## Layout

- `data/` holds one data file per compilation. The structure is free; today it is `.tsv` with `#` metadata lines and a column header.
- `display/` holds the generated pages.
- `build_display.py` builds the pages from `data/` (Python 3, standard library only).

## Naming

`<UTC>_<compiler>.tsv`, for example `20261028T1927Z_silica-compiler-4a63c6254fb6.tsv`.

## How data gets there

The compiler build (`compiler/src/Makefile`) writes one file per build through `programmer_tools/ram_profile_unit.sh`. No other makefile writes RAM profiles. `SILICA_RAM_PROFILE=0` disables it.

A profile is written only when a build compiles at least one unit; an up-to-date build writes none.

The newest profile sets the per-job RAM figure `PER_JOB_MB` the Makefile uses for its default `JOBS`: the largest unit `peak_footprint_MB`, rounded up to a multiple of 64 MB, floor 512 MB; 2048 when no profile can be read. `make -C compiler/src print-jobs` shows the figure and its source; `make -C compiler/src ram-compare` (read-only) prints the largest units and the figure. See `compiler/src/README.md`.

## Views

- dev: every data file.
- published: only files tracked by git, that is, checked in.

A new data file is not in the published view until it is committed.

## Building the pages

```sh
python3 build_display.py --view dev
python3 build_display.py --view published
python3 build_display.py --watch      # rebuild both views on change; Ctrl-C or SIGTERM stops
```

## Server port

The server's default port comes from the first three letters of the word "silica". Each letter is replaced by its position in the alphabet (a=1 ... z=26): s=19, i=9, l=12. The three numbers are written one after another, 19 then 9 then 12, giving 19912.

- The default port is 19912.
- `--port N` overrides it, in both `build_display.py` and `build_and_show.sh`.
- The server binds to 127.0.0.1 only.

## Page contents

One view: a per-unit comparison across runs. There are no tabs and no filters (the run, compiler, date, measure, unit-name, minimum-peak and maximum-units filters, the run picker and the unit dropdown were removed); every loaded run and every unit is shown.

- **Metric buttons** above the chart: 'RAM used to compile each unit (MB)' and 'Compile time for each unit (seconds)'. The selected button sets the vertical axis and the dots. The choice is remembered in the browser (localStorage, key 'ram-report-metric'); the default is RAM used.
- **Dot plot**: one narrow column (7 px) per compilation unit, ordered by source folder alphabetically, then unit name alphabetically (not by size), so the chart scrolls sideways. The vertical axis is at the left with about 6 tick labels and a title showing the selected metric. Each run is a dot in each unit's column, coloured by run; the legend above the chart shows each run's colour and short label (timestamp and compiler).
- **No names on the chart**: no unit names and no folder names are drawn anywhere on it. Names and paths appear only in the hover popup.
- **Hover popup**, shown beside the pointer: the data-file path, the unit's full path, the run, RAM used (MB), the unit's compile seconds and the run's total seconds, exit code, and source lines and bytes when the data has them. Shift + / Shift - / Shift 0 enlarge, shrink and reset the popup text, 8-32 px in 2 px steps, default 11, remembered in the browser (localStorage, key 'ram-report-popup').
- A note listing any data files that were skipped, the 'last built' line, and an auto-update checkbox (the page reloads when the server pushes a change).
