#!/usr/bin/env python3
# Integrate helper: run a trial with stdout/stderr on a PTY (line-oriented stdio) and stdin on a pipe.
# Feed "exit\n" to stdin only after a full line contains <marker> (e.g. supervisor "done") **and** the PTY has
# been quiet for a short idle window (bounded). Some trials (e4f) print `done` before async failure banners;
# sending exit on `done` alone tears down the process early → SIGBUS / `.sout` with only the exit code.
# Matching by containment handles concurrent stdout fragments that glue onto the marker line, such as
# `doneF8_handle_report_banner_ok`, without hanging forever.
# Appends the process exit code as the final line (same as echo $? in run_integration_binary.sh).
"""Usage: run_integration_exit_after_marker.py <trial_dir> <basename> <out_path> <marker_line>"""

import errno
import os
import pty
import select
import signal
import sys
import termios
import time


def quiesce_pty(
    master: int, out_f, idle_sec: float = 0.08, cap_sec: float = 3.0
) -> None:
    """Keep reading the PTY until `idle_sec` passes with no readable data, or `cap_sec` total wall time."""
    deadline = time.monotonic() + cap_sec
    while time.monotonic() < deadline:
        timeout = min(idle_sec, deadline - time.monotonic())
        if timeout <= 0:
            break
        r, _, _ = select.select([master], [], [], timeout)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:   # Linux: child gone, treat as EOF (macOS gives b"")
                    return
                raise
            if not chunk:
                return
            out_f.write(chunk)
        else:
            # select timed out: no data for `timeout` (≤ idle_sec) → trailing output drained
            return


def main() -> int:
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: run_integration_exit_after_marker.py "
            "<trial_dir> <basename> <out_path> <marker_line>\n"
        )
        return 2

    trial_dir, base, out_path, marker = sys.argv[1:5]
    exe = os.path.join(trial_dir, base)
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
        sys.stderr.write(f"missing or not executable: {exe}\n")
        return 1

    marker_b = marker.encode("utf-8")
    # No run time limit of its own: a trial that never prints the marker is killed by the
    # integrate watchdog (silica_compiler.mk), which signals this runner's process group.
    # SILICA_INTEGRATION_MARKER_TIMEOUT_SEC may still set a limit for a manual run.
    timeout_env = os.environ.get("SILICA_INTEGRATION_MARKER_TIMEOUT_SEC", "")
    timeout_sec = float(timeout_env) if timeout_env else float("inf")
    retry_limit = int(os.environ.get("SILICA_INTEGRATION_MARKER_RETRY_137", "3"))
    retry_attempt = int(os.environ.get("SILICA_INTEGRATION_MARKER_RETRY_ATTEMPT", "0"))

    master, slave = pty.openpty()
    # Do not let the kernel rewrite \n as \r\n in the program's output.
    attrs = termios.tcgetattr(slave)
    attrs[1] &= ~termios.OPOST
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    stdin_r, stdin_w = os.pipe()

    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.close(stdin_w)
        try:
            os.setsid()
        except OSError:
            pass
        os.dup2(stdin_r, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        if stdin_r > 2:
            os.close(stdin_r)
        if slave > 2:
            os.close(slave)
        os.chdir(trial_dir)
        os.execv(exe, [exe])
        return 127

    os.close(stdin_r)
    os.close(slave)

    # The trial runs in its own session (os.setsid above), so a signal to this runner's
    # process group does not reach it: forward the watchdog's SIGTERM to the trial and
    # exit; the makefile reports the trial as incomplete.
    def forward_term(signum, frame):
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, forward_term)

    exit_sent = False
    marker_seen = False
    buf = b""
    deadline = time.monotonic() + timeout_sec
    timed_out = False
    try:
        with open(out_path, "wb", buffering=0) as out_f:
            while True:
                now = time.monotonic()
                if not exit_sent and now >= deadline:
                    out_f.write(
                        f"run_integration_exit_after_marker.py: timed out waiting for marker {marker!r}\n".encode(
                            "utf-8"
                        )
                    )
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    timed_out = True
                    break
                wait_sec = 0.25
                if not exit_sent:
                    wait_sec = max(0.0, min(wait_sec, deadline - now))
                r, _, _ = select.select([master], [], [], wait_sec)
                if not r:
                    continue
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    # Linux raises EIO on the PTY master once the child has exited and closed the
                    # slave; macOS returns b"" (EOF). Both mean "no more output".
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                out_f.write(chunk)
                if not exit_sent:
                    buf += chunk
                    while True:
                        idx = buf.find(b"\n")
                        if idx < 0:
                            break
                        line = buf[:idx].rstrip(b"\r")
                        buf = buf[idx + 1 :]
                        if marker_b in line:
                            marker_seen = True
                            quiesce_pty(master, out_f)
                            try:
                                os.write(stdin_w, b"exit\n")
                            except BrokenPipeError:
                                pass
                            except OSError as exc:
                                if exc.errno != errno.EPIPE:
                                    raise
                            exit_sent = True
                            break
    finally:
        try:
            os.close(stdin_w)
        except OSError:
            pass

    if timed_out:
        time.sleep(0.1)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    _pid, wstatus = os.waitpid(pid, 0)
    try:
        os.close(master)
    except OSError:
        pass

    if os.WIFEXITED(wstatus):
        code = os.WEXITSTATUS(wstatus)
    elif os.WIFSIGNALED(wstatus):
        code = 128 + os.WTERMSIG(wstatus)
    else:
        code = 1

    # A small number of supervisor trials can still trip a macOS arm64 runtime
    # cleanup timing failure under PTY execution, producing SIGKILL before the
    # marker while a direct run succeeds. Treat that specific pre-marker 137 as
    # a flaky sample and rerun with a fresh process/output file.
    if code == 137 and not marker_seen and retry_attempt < retry_limit:
        os.environ["SILICA_INTEGRATION_MARKER_RETRY_ATTEMPT"] = str(retry_attempt + 1)
        os.execv(sys.executable, [sys.executable] + sys.argv)

    with open(out_path, "ab", buffering=0) as out_f:
        out_f.write(f"{code}\n".encode("ascii"))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
