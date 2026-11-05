#!/usr/bin/env bash
# stop_display.sh - stop the memory-use display server started by build_display.py --serve.
#
# Usage: stop_display.sh [--port N]
#   --port N   port of the server to stop (digits only, default 19912)
#
# Looks for display/serve-N.pid beside this script. If it is missing, falls back
# to pgrep on the command line "build_display.py --serve --view ... --port N".
# Only processes belonging to that port's server are signalled.
#
# Exit codes: 0 stopped or nothing to stop, 1 port still answering, 2 usage error.

set -uo pipefail

PORT=19912
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "usage: $0 [--port N]  (N digits only)" >&2
        exit 2
      fi
      PORT="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--port N]" >&2
      exit 2
      ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDF="$HERE/display/serve-$PORT.pid"

# stop_pid PID: SIGTERM, wait up to 10 s (poll 0.2 s), SIGKILL if needed.
stop_pid() {
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null
  for ((i = 0; i < 50; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    echo "server pid $pid on port $PORT did not exit within 10 s; sent SIGKILL"
  else
    echo "stopped server pid $pid on port $PORT"
  fi
}

found=0
if [ -f "$PIDF" ]; then
  found=1
  pid="$(tr -d '[:space:]' < "$PIDF")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    stop_pid "$pid"
  else
    echo "pid file is stale (pid ${pid:-?} not running); removing it"
  fi
  rm -f "$PIDF"
else
  pids="$(pgrep -f "build_display.py --serve --view .* --port $PORT( |\$)" || true)"
  for pid in $pids; do
    [ "$pid" = "$$" ] && continue
    found=1
    stop_pid "$pid"
  done
  if [ "$found" -eq 0 ]; then
    echo "no display server running on port $PORT"
    exit 0
  fi
fi

if python3 - "$PORT" <<'EOF'
import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
sys.exit(0)
EOF
then
  echo "warning: port $PORT is still answering after stop" >&2
  exit 1
fi
echo "port $PORT is free"
exit 0
