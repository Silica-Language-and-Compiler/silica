#!/usr/bin/env python3
"""Collect the assembly a trial run generated, named as its golden copies.

  collect_goldens.py --trials trials --target <matrix target> --out <dir>

Every generated <stem>.sams is copied to <dir>/<path relative to trials/>/<stem><golden extension>,
which is what trials/update_golden_assembly.sh would produce, plus the per-target name the
Makefiles compare against (trials/silica_compiler.mk ASCOMP_EXT):

  apple_silicon_mac  <stem>.ascomp
  linux_aarch64      <stem>.linux_aarch64.ascomp
  linux_x86_64       <stem>.linux_x86_64.ascomp
  ESP32-S3_raw       <stem>.esp32_s3.ascomp      (TARGET_ASCOMP_PLATFORM of trials/targets/ESP32-S3_raw.conf)

Hosted runs leave the .sams next to the trial sources. A board run compiles in
trials/.target/<target>/<suite>/src/ (and .../apps/<app>/ for the ffi_addition apps) and compares
with the golden next to the trial, so those paths map back to <suite>/<stem>... and
<suite>/<app>/<stem>... Hidden directories and symlinks are not collected.

Writes <dir>/MANIFEST.txt: `target=<target>` on the first line, then one relative path per line.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil

HOST_EXT = {
    "apple_silicon_mac": ".ascomp",
    "linux_aarch64": ".linux_aarch64.ascomp",
    "linux_x86_64": ".linux_x86_64.ascomp",
}


def golden_ext(trials: str, target: str) -> str:
    if target in HOST_EXT:
        return HOST_EXT[target]
    conf = os.path.join(trials, "targets", target + ".conf")
    if not os.path.isfile(conf):
        raise SystemExit("unknown target %s (no %s)" % (target, conf))
    with open(conf, encoding="utf-8") as handle:
        for line in handle:
            m = re.match(r'\s*TARGET_ASCOMP_PLATFORM="?([A-Za-z0-9_.-]*)"?', line)
            if m and m.group(1):
                return ".%s.ascomp" % m.group(1)
    raise SystemExit("%s sets no TARGET_ASCOMP_PLATFORM" % conf)


def walk_sams(root: str):
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            full = os.path.join(dirpath, name)
            if name.endswith(".sams") and not os.path.islink(full):
                yield full


def collect(trials: str, target: str) -> list[tuple[str, str]]:
    """(source file, path relative to trials/ of its golden copy), sorted by the latter."""
    ext = golden_ext(trials, target)
    found: list[tuple[str, str]] = []
    if target in HOST_EXT:
        for full in walk_sams(trials):
            rel = os.path.relpath(full, trials)
            found.append((full, rel[: -len(".sams")] + ext))
    else:
        base = os.path.join(trials, ".target", target)
        if os.path.isdir(base):
            for suite in sorted(os.listdir(base)):
                work = os.path.join(base, suite)
                if suite.startswith(".") or not os.path.isdir(work):
                    continue
                for sub in ("src", "apps"):
                    root = os.path.join(work, sub)
                    if not os.path.isdir(root):
                        continue
                    for full in walk_sams(root):
                        inner = os.path.relpath(full, root)
                        # apps/<app>/<stem>.sams -> <suite>/<app>/<stem>; src/<path> -> <suite>/<path>
                        rel = os.path.join(suite, inner)
                        found.append((full, rel[: -len(".sams")] + ext))
    return sorted(found, key=lambda item: item[1])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    items = collect(args.trials, args.target)
    os.makedirs(args.out, exist_ok=True)
    seen: set[str] = set()
    names: list[str] = []
    for src, rel in items:
        if rel in seen:
            continue
        seen.add(rel)
        dest = os.path.join(args.out, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(src, dest)
        names.append(rel)
    with open(os.path.join(args.out, "MANIFEST.txt"), "w", encoding="utf-8") as handle:
        handle.write("target=%s\n" % args.target)
        for rel in names:
            handle.write(rel + "\n")
    print("%d golden copies for %s in %s" % (len(names), args.target, args.out))


if __name__ == "__main__":
    main()
