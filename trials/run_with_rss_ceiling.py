#!/usr/bin/env python3
# Integrate helper: run one host trial and fail it when its peak resident set size is above the
# ceiling in its <trial>.max_rss_mb marker (one integer, megabytes = MiB, 2^20 bytes).
#
# Called only by INTEGRATE_RUN_TRIAL / INTEGRATE_EXEC_TRIAL in silica_compiler.mk, and only when the
# marker exists and the trial runs on this host; see trials/README.md ("Peak memory ceiling").
#
#   run_with_rss_ceiling.py <label> <max_rss_mb file> <sout path> -- <command> [args...]
#
# <command> is the trial itself (./<trial>) or the runner that drives it
# (run_integration_exit_after_marker.py). It runs as this process's child and is reaped with
# wait4(), whose ru_maxrss is the peak of the child and of every descendant it reaped (the trial
# under the marker runner): the same number `/usr/bin/time -l` (macOS) and `/usr/bin/time -v`
# (Linux) print, read straight from the kernel instead of parsed from time's stderr, which would land
# in the .sout. Units: macOS reports bytes, Linux (and the BSDs) kilobytes.
#
# A peak above the ceiling appends one line to <sout path>, so the .sout no longer matches the
# .scout and the trial fails through the suite's normal comparison: a pass needs the right output
# AND a peak within the ceiling. Nothing is appended otherwise. One verdict line (✅ / ❌ + label,
# peak and ceiling) goes to file descriptor 7 when the caller opened it (the suite's log).
#
# Hard timeout: SILICA_RSS_TRIAL_TIMEOUT_SEC (default 600). When it expires the child gets SIGTERM
# (the marker runner forwards it to the trial), then SIGKILL 5 s later; a timeout line is appended
# to <sout path>. Both delays are interval timers, not sleeps.
# Exit status: the child's (128 + signal number when a signal ended it), so the .sout's exit-code
# line is the one an unwrapped run writes.

import os
import signal
import sys

MIB = 1024 * 1024
KILL_GRACE_SEC = 5.0


def append(path: str, line: str) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def note(line: str) -> None:
    try:
        os.write(7, (line + "\n").encode("utf-8"))
    except OSError:
        pass


def read_ceiling(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            words = f.read().split()
    except OSError:
        return None
    if len(words) != 1 or not words[0].isdigit() or int(words[0]) <= 0:
        return None
    return int(words[0])


def peak_bytes(ru_maxrss: int) -> int:
    # macOS: bytes. Linux and the BSDs: kilobytes. (Linux path untested; see trials/README.md.)
    return ru_maxrss if sys.platform == "darwin" else ru_maxrss * 1024


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 5 or args[3] != "--":
        sys.stderr.write(
            "usage: run_with_rss_ceiling.py <label> <max_rss_mb file> <sout path> -- <command> [args...]\n"
        )
        return 2
    label, marker, sout = args[0], args[1], args[2]
    command = args[4:]
    marker_name = os.path.basename(marker)

    ceiling = read_ceiling(marker)
    if ceiling is None:
        msg = f"max_rss_mb: {marker_name} must hold one positive integer (megabytes); trial not run"
        append(sout, msg)
        note(f"❌ {label}: {msg}")
        return 1

    timeout_sec = float(os.environ.get("SILICA_RSS_TRIAL_TIMEOUT_SEC", "600"))

    pid = os.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError as exc:
            os.write(2, f"run_with_rss_ceiling.py: cannot run {command[0]}: {exc}\n".encode("utf-8"))
        os._exit(127)

    timed_out = [False]

    def on_alarm(signum, frame):
        if not timed_out[0]:
            timed_out[0] = True
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            signal.setitimer(signal.ITIMER_REAL, KILL_GRACE_SEC)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout_sec)
    # wait4 is retried after the handler runs (PEP 475), so the alarm only sends signals.
    _pid, status, rusage = os.wait4(pid, 0)
    signal.setitimer(signal.ITIMER_REAL, 0)

    if os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        code = 128 + os.WTERMSIG(status)
    else:
        code = 1

    peak = peak_bytes(rusage.ru_maxrss)
    peak_mb = peak / MIB
    if timed_out[0]:
        msg = f"max_rss_mb: hard timeout: the run was stopped after {timeout_sec:g} s (peak resident set size {peak_mb:.1f} MB so far)"
        append(sout, msg)
        note(f"❌ {label}: {msg}")
    elif peak > ceiling * MIB:
        msg = f"max_rss_mb: peak resident set size {peak_mb:.1f} MB exceeds the ceiling of {ceiling} MB ({marker_name})"
        append(sout, msg)
        note(f"❌ {label}: {msg}")
    else:
        note(f"✅ {label} peak resident set size {peak_mb:.1f} MB is within the ceiling of {ceiling} MB")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
