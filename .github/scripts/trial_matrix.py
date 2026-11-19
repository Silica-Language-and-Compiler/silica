#!/usr/bin/env python3
"""Build the Trials workflow matrix: one row per target and shard.

Suites are the top-level trials/* directories that have a Makefile and are not
marked INTEGRATE_PENDING. That is the set `make integrate` runs. A pending
suite stays out, including the board suites that a whole-tree board run skips
until they are named on their own.

Suites are packed into N shards by source count, heaviest first.
error_enforcement_addition is about half the sources, so every shard also
runs one slice of it (TRIAL_SUITE_SLICE). The pack is deterministic.
"""

from __future__ import annotations

import argparse
import json
import os

TARGETS = (
    "apple_silicon_mac",
    "linux_aarch64",
    "linux_x86_64",
    "ESP32-S3_raw",
)

RUNNERS = {
    "apple_silicon_mac": "macos-26",
    "linux_aarch64": "ubuntu-24.04-arm",
    "linux_x86_64": "ubuntu-24.04",
    "ESP32-S3_raw": "macos-26",
}

# On the matching runner, "host" is that machine. ESP32-S3_raw is the board
# target; the workflow points it at QEMU.
TRIAL_TARGET = {
    "apple_silicon_mac": "host",
    "linux_aarch64": "host",
    "linux_x86_64": "host",
    "ESP32-S3_raw": "ESP32-S3_raw",
}

# This suite is large enough that giving it a whole shard wastes the other fourteen.
SLICED_SUITE = "error_enforcement_addition"


def suites_of(trials: str) -> list[tuple[str, int]]:
    found = []
    for name in sorted(os.listdir(trials)):
        path = os.path.join(trials, name)
        if not os.path.isdir(path):
            continue
        if not (os.path.isfile(os.path.join(path, "Makefile")) or os.path.isfile(os.path.join(path, "makefile"))):
            continue
        if os.path.isfile(os.path.join(path, "INTEGRATE_PENDING")):
            continue
        weight = 0
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            weight += sum(1 for f in files if f.endswith(".silica"))
        found.append((name, max(weight, 1)))
    if not found:
        raise SystemExit("no trial suites under %s" % trials)
    return found


def pack(weighted: list[tuple[str, int]], shards: int) -> list[list[str]]:
    bins: list[list[str]] = [[] for _ in range(shards)]
    loads = [0] * shards
    for name, weight in sorted(weighted, key=lambda item: (-item[1], item[0])):
        index = min(range(shards), key=lambda i: (loads[i], i))
        bins[index].append(name)
        loads[index] += weight
    return [sorted(bin_) for bin_ in bins]


def matrix(trials: str, target: str, shards: int) -> list[dict[str, object]]:
    if target == "all":
        chosen = list(TARGETS)
    elif target in TARGETS:
        chosen = [target]
    else:
        raise SystemExit("unknown target %s" % target)
    all_suites = suites_of(trials)
    if not any(name == SLICED_SUITE for name, _weight in all_suites):
        raise SystemExit("missing suite %s" % SLICED_SUITE)
    weighted = [(name, weight) for name, weight in all_suites if name != SLICED_SUITE]
    packed = pack(weighted, shards)
    rows = []
    for name in chosen:
        for shard in range(shards):
            suites = list(packed[shard])
            suites.append(SLICED_SUITE)
            rows.append({
                "target": name,
                "shard": shard,
                "runner": RUNNERS[name],
                "trial_target": TRIAL_TARGET[name],
                "suites": " ".join(sorted(suites)),
                "suite_slice": "%s:%d:%d" % (SLICED_SUITE, shards, shard),
            })
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--shards", type=int, default=15)
    args = ap.parse_args()
    if args.shards < 1:
        raise SystemExit("--shards must be at least 1")
    print(json.dumps(matrix(args.trials, args.target, args.shards), separators=(",", ":")))


if __name__ == "__main__":
    main()
