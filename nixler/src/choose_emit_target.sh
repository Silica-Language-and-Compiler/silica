#!/bin/sh
# Interactive emit-target menu for src (called from emit_target.mk when TARGET is
# not given on the command line or in the environment).
#
#   choose_emit_target.sh <host-default> <allowed target>...
#
# Prints the chosen target name on stdout. The menu goes to /dev/tty so make's $(shell)
# capture only sees the answer. With no usable terminal (CI, nohup, a piped make) the
# host default is printed without asking, so non-interactive builds behave as before.
default="$1"; shift
if [ $# -eq 0 ]; then exit 0; fi
# The probe uses `true`, not `:`. `:` is a special builtin, and POSIX lets a non-interactive
# shell exit outright when a redirection on a special builtin fails; dash (Debian's /bin/sh)
# does exactly that, so on Linux with no controlling terminal the script died here without
# printing anything and every headless build failed its target check.
if ! { true </dev/tty; } 2>/dev/null || ! { true >/dev/tty; } 2>/dev/null; then
    printf '%s\n' "$default"; exit 0
fi
while :; do
    {
        printf 'Select the emit target (emitter/<name>/ to bake into silica-compiler):\n'
        i=0
        for t in "$@"; do
            i=$((i + 1))
            if [ "$t" = "$default" ]; then printf '  %d) %s  [default: host]\n' "$i" "$t"; else printf '  %d) %s\n' "$i" "$t"; fi
        done
        printf 'Number or name'
        if [ -n "$default" ]; then printf ' [%s]' "$default"; fi
        printf ': '
    } >/dev/tty
    read -r answer </dev/tty || { printf '%s\n' "$default"; exit 0; }
    if [ -z "$answer" ]; then
        if [ -n "$default" ]; then printf '%s\n' "$default"; exit 0; fi
        continue
    fi
    i=0
    for t in "$@"; do
        i=$((i + 1))
        if [ "$answer" = "$i" ] || [ "$answer" = "$t" ]; then printf '%s\n' "$t"; exit 0; fi
    done
    printf 'Unknown target "%s"; pick one of the listed numbers or names.\n' "$answer" >/dev/tty
done
