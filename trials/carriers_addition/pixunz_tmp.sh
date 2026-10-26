set -u
cd "$1" || exit 1
make all SILICA_COMPILER="$2" </dev/null 2>&1 | grep -A3 "^E[0-9]\|zpin.*(clang)\|zpin.*(rust-lld)"
F=workers_zpin_pin_performance_efficiency
for c in unset 1 2 4; do
  if [ $c = unset ]; then ./$F > o.$c; else SILICA_CARRIER_COUNT=$c ./$F > o.$c; fi
  echo "$?" >> o.$c
  if diff o.$c "$3" >/dev/null; then echo "$c OK"; else echo "$c DIFF: $(tr '\n' ' ' < o.$c)"; fi
done
