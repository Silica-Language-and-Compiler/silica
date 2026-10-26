#!/usr/bin/env bash
# Platform-neutral entry point; retain run_board_app.sh for compatibility.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_board_app.sh" "$@"
