#!/usr/bin/env bash
# Time how long it takes to start 1,000,000 idle actors, then stop the program.
#
#   bash run_million_actors.sh [--send] [target-count]    (default 1000000)
#
#   --send   cast one message to each actor right after it is spawned. The first dispatch
#            commits a stack for the actor, which is what :release_when_idle later gives back;
#            without it the actors never run and never hold a stack (the earlier README
#            measurements of 5.48 s and a 1,262 MB peak were taken this way).
#
# Builds a scratch copy of docs/examples/idle_actor_capacity whose spawner stops
# casting itself once the running total reaches the target, runs it, prints the
# elapsed time at the line "<target> idle actors", and sends "exit".
# Works on macOS (Apple silicon) and Linux (x86-64, AArch64). Never touches the repo.
set -euo pipefail

SEND=0
if [ "${1:-}" = "--send" ]; then SEND=1; shift; fi
TARGET="${1:-1000000}"
REPO="${SILICA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMPILER="${SILICA_COMPILER:-$REPO/binaries/silica-compiler}"
SRC="$REPO/docs/examples/idle_actor_capacity/main.silica"

[ -x "$COMPILER" ] || { echo "no compiler at $COMPILER (set SILICA_COMPILER)" >&2; exit 2; }
[ -f "$SRC" ] || { echo "no source at $SRC (set SILICA_REPO)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$SRC" "$WORK/main.silica"
cd "$WORK"

# Stop the spawner's self-cast once the total reaches the target (only the spawner's
# cast, the one that ends without a semicolon; the first-message cast in main is kept).
TARGET="$TARGET" SEND="$SEND" python3 - <<'PY'
import os
p = "main.silica"
lines = open(p).read().split("\n")
old = "_: boolean <- cast_registered(:spawner, 0 impl ActorMessage {})"
idx = [i for i, l in enumerate(lines) if old in l and not l.rstrip().endswith(";")]
assert len(idx) == 1, "expected exactly one spawner cast, found %d" % len(idx)
t = os.environ["TARGET"]
lines[idx[0]] = lines[idx[0]].replace(
    old,
    "_: boolean <- case new_total >= %s of {\n"
    "            true -> true;\n"
    "            false -> cast_registered(:spawner, 0 impl ActorMessage {})\n"
    "        }" % t)
text = "\n".join(lines)
if os.environ["SEND"] == "1":
    spawn = "_: actor_ref <- spawn(0, idle, stack_policy(reserve_bytes(), :release_when_idle));"
    assert text.count(spawn) == 1, "expected exactly one idle spawn"
    text = text.replace(
        spawn,
        "a: actor_ref <- spawn(0, idle, stack_policy(reserve_bytes(), :release_when_idle));\n"
        "                _: boolean <- cast(a, 0 impl ActorMessage {});")
open(p, "w").write(text)
PY

echo main.silica > silica.config
echo "== compiling with $COMPILER"
"$COMPILER" >compile.log 2>&1 || { cat compile.log; echo "compile failed" >&2; exit 1; }

echo "== assembling and linking"
case "$(uname -s)" in
  Darwin)
    clang -c -x assembler main.sams -o main.o
    clang -c -x assembler __silica_runtime.sams -o __silica_runtime.o
    clang main.o __silica_runtime.o -o idle_actor_capacity -Wl,-e,main ;;
  Linux)
    cc -c -x assembler main.sams -o main.o
    cc -c -x assembler __silica_runtime.sams -o __silica_runtime.o
    cc main.o __silica_runtime.o -o idle_actor_capacity -no-pie -rdynamic -lpthread ;;
  *) echo "unsupported OS $(uname -s)" >&2; exit 2 ;;
esac

echo "== running (target $TARGET idle actors, send message: $([ "$SEND" = 1 ] && echo yes || echo no))"
REST_SECONDS="${REST_SECONDS:-4}" TARGET="$TARGET" python3 - <<'PY'
import os, subprocess, sys, threading, time

target = os.environ["TARGET"]
rest_seconds = float(os.environ["REST_SECONDS"])
is_linux = sys.platform.startswith("linux")


def rss_mb(pid):
    """Resident set size of pid in MB, or None if it cannot be read."""
    try:
        if is_linux:
            with open("/proc/%d/status" % pid) as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1]) / 1024.0
            return None
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        return int(out) / 1024.0 if out else None
    except (OSError, ValueError):
        return None


def threads(pid):
    if not is_linux:
        return None
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("Threads:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


t0 = time.time()
p = subprocess.Popen(["./idle_actor_capacity"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, text=True)

peak = [0.0]
peak_threads = [0]
stop = threading.Event()


def sampler():
    while not stop.is_set():
        r = rss_mb(p.pid)
        if r is not None and r > peak[0]:
            peak[0] = r
        n = threads(p.pid)
        if n is not None and n > peak_threads[0]:
            peak_threads[0] = n
        time.sleep(0.05)


threading.Thread(target=sampler, daemon=True).start()

reached = False
last = ""
at_target = None
for line in p.stdout:
    last = line.strip()
    if line.startswith(target + " "):
        elapsed = time.time() - t0
        at_target = rss_mb(p.pid)
        if at_target is not None and at_target > peak[0]:
            peak[0] = at_target
        print("%s  after %.2f s" % (last, elapsed))
        reached = True
        break
    if time.time() - t0 > 600:
        print("gave up after 600 s; last line: " + last)
        break

at_rest = None
if reached:
    # The idle stacks are given back after the idle period (default 1 s), so sample again later.
    time.sleep(rest_seconds)
    at_rest = rss_mb(p.pid)

stop.set()
try:
    p.stdin.write("exit\n"); p.stdin.flush()
except BrokenPipeError:
    pass
try:
    rc = p.wait(timeout=30)
except subprocess.TimeoutExpired:
    p.kill(); rc = p.wait()
    print("did not exit within 30 s of 'exit'; killed")


def fmt(v):
    return "not read" if v is None else "%.0f MB" % v


print("RSS when the target line printed : %s" % fmt(at_target))
print("RSS peak while running           : %s" % fmt(peak[0] or None))
print("RSS %.0f s after the target (rest) : %s" % (rest_seconds, fmt(at_rest)))
if is_linux:
    print("peak thread count                : %d" % peak_threads[0])
print("exit status %s" % rc)
sys.exit(0 if reached else 1)
PY
