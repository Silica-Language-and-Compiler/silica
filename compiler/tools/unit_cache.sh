#!/usr/bin/env bash
# Content-hash staleness for compiler/src's Stage 1 (Silica -> .sams/.iface), with early cutoff.
#
# Replaces the old mtime rule (keep a unit's .sams/.iface when newer than its .silica and the
# host compiler). mtimes say nothing after a fresh checkout or a restored CI cache, and the old
# rule never looked at the units a unit uses, so a changed exported signature left every
# dependent built against the old one.
#
# A unit is rebuilt when any of these differ from what its manifest entry recorded:
#   - the context: this script's schema, TARGET and the sha256 of the host compiler binary;
#   - the sha256 of the unit's own source;
#   - the interface fingerprint of every unit it uses, directly or transitively.
# The interface fingerprint of a unit is the sha256 of its .iface without the source_hash= and
# deps_hash= lines (those change on every body edit). A unit that declares or implements a trait
# (export_trait= set, or impl_count= not 0) is fingerprinted by its whole source instead, because
# trait specialization works from the AST, not the .iface. So a body-only edit rebuilds that unit
# alone; a changed interface also rebuilds what uses it (early cutoff).
#
# Whether a unit's interface changed is known only after it compiles, so the build runs in rounds:
#   plan    -> the units that must compile now (.unit_cache.dirty) and the ones that wait for a
#              dependency to compile first (undecided). Dirty units lose their .sams/.iface/.o and
#              their manifest entry, so a batch that fails part-way leaves nothing trusted.
#   (the Makefile compiles .unit_cache.dirty as one batch)
#   record  -> manifest entries for the units of that batch, with the interfaces they were built
#              against.
# and plan again, until no unit is dirty. A unit is undecided while any unit it uses is dirty or
# undecided; it is never compiled in the same round as an undecided dependency.
#
# Usage (from the Makefile, working directory = the target's build directory):
#   unit_cache.sh plan   <src_dir> <host_compiler> <target>
#   unit_cache.sh record <src_dir> <host_compiler> <target> <units_file>
#   unit_cache.sh status <src_dir> <host_compiler> <target>      # plan without touching anything
#
# Manifest: .unit_cache.manifest, tab separated: unit, context, source sha256, deps fingerprint
# (the sha256 of its transitive uses' interface fingerprints). .unit_cache.deps keeps those
# fingerprints one per line (unit, used unit, fingerprint), so that once a used unit has been
# rebuilt with a new interface every unit built against the old one is dirty in the very next
# round, not one dependency layer per round.
# A build directory without a manifest (made before this script) is adopted once: a unit whose
# .sams and .iface are newer than its source and the compiler (the old rule) is taken as built
# with the current inputs, so the first build after the change does not recompile everything.
set -euo pipefail

SCHEMA="unit_cache v1"
MANIFEST=".unit_cache.manifest"
DIRTY_FILE=".unit_cache.dirty"
DEPS_FILE=".unit_cache.deps"

usage() {
  echo "Usage: $0 plan|status <src_dir> <host_compiler> <target>" >&2
  echo "       $0 record <src_dir> <host_compiler> <target> <units_file>" >&2
  exit 2
}

[ $# -ge 4 ] || usage
CMD=$1
SRC_DIR=$2
COMPILER=$3
TARGET=$4
case "$CMD" in
  plan|status) [ $# -eq 4 ] || usage ;;
  record) [ $# -eq 5 ] || usage; RECORD_UNITS=$5 ;;
  *) usage ;;
esac
[ -f silica.config ] || { echo "unit_cache: no silica.config in $(pwd)" >&2; exit 1; }
[ -e "$COMPILER" ] || { echo "unit_cache: host compiler missing: $COMPILER" >&2; exit 1; }

# sha256 tool: GNU coreutils on Linux, shasum on macOS. Word-split on purpose where used.
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
sha256() { $SHA "$@"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Units in silica.config order (topological: every unit after the units it uses).
grep -v -e '^[[:space:]]*$' -e '^#' silica.config > "$WORK/units"

compiler_sha=$(sha256 "$COMPILER" | awk '{ print $1 }')
CONTEXT=$(printf '%s\n%s\n%s\n' "$SCHEMA" "$TARGET" "$compiler_sha" | sha256 | awk '{ print $1 }')

"$SRC_DIR/topo_silica_config.sh" --edges "$TARGET" > "$WORK/edges"

# sha256 of each unit's source (the staged links resolve to src/).
tr '\n' '\0' < "$WORK/units" | xargs -0 $SHA \
  | awk '{ h = $1; sub(/^[0-9a-f]+ [ *]?/, ""); print $0 "\t" h }' > "$WORK/src_sha"

# Units whose .sams and .iface both exist; for those, the interface fingerprint input.
: > "$WORK/present"
mkdir -p "$WORK/iface"
n=0
while IFS= read -r u; do
  base=${u%.silica}
  if [ -f "$base.sams" ] && [ -f "$base.iface" ]; then
    n=$((n + 1))
    printf '%s\t%s\n' "$u" "$n" >> "$WORK/present"
    awk -v out="$WORK/iface/$n" -v trait_out="$WORK/iface/$n.trait" '
      /^source_hash=/ || /^deps_hash=/ { next }
      /^export_trait=./ { trait = 1 }
      /^impl_count=/ && $0 != "impl_count=0" { trait = 1 }
      { print > out }
      END { close(out); if (trait) { print "1" > trait_out } }
    ' "$base.iface"
  fi
done < "$WORK/units"

# Interface fingerprint per present unit: the stripped .iface, or the source for trait units.
: > "$WORK/iface_fp"
if [ -s "$WORK/present" ]; then
  (cd "$WORK/iface" && ls | grep -v '\.trait$' | sort -n | tr '\n' '\0' | xargs -0 $SHA) \
    | awk '{ print $2 "\t" $1 }' > "$WORK/iface_sha_by_n"
  for t in "$WORK"/iface/*.trait; do
    [ -e "$t" ] || continue
    t=${t##*/}; echo "${t%.trait}"
  done > "$WORK/trait_n"
  awk -F'\t' -v present="$WORK/present" -v ish="$WORK/iface_sha_by_n" -v trait="$WORK/trait_n" -v src="$WORK/src_sha" '
    BEGIN {
      while ((getline l < ish) > 0) { split(l, a, "\t"); by_n[a[1]] = a[2] }
      while ((getline l < trait) > 0) is_trait[l] = 1
      while ((getline l < src) > 0) { split(l, a, "\t"); s[a[1]] = a[2] }
      while ((getline l < present) > 0) {
        split(l, a, "\t")
        print a[1] "\t" ((a[2] in is_trait) ? "src:" s[a[1]] : "iface:" by_n[a[2]])
      }
    }' > "$WORK/iface_fp"
fi

# Transitive uses of each unit (in silica.config order), and the text its deps fingerprint is
# the sha256 of: one "<unit> <interface fingerprint>" line per transitive use, MISSING when that
# unit has no .iface yet. One file per unit, hashed in a single call.
mkdir -p "$WORK/deps"
awk -F'\t' -v units="$WORK/units" -v edges="$WORK/edges" -v fp="$WORK/iface_fp" \
    -v depsdir="$WORK/deps" -v tdeps_out="$WORK/tdeps" '
  BEGIN {
    while ((getline l < fp) > 0) { split(l, a, "\t"); f[a[1]] = a[2] }
    while ((getline l < edges) > 0) { split(l, a, "\t"); direct[a[2]] = direct[a[2]] a[1] "\n" }
    nu = 0
    while ((getline u < units) > 0) { order[++nu] = u; pos[u] = nu }
    for (i = 1; i <= nu; i++) {
      u = order[i]
      delete want
      nd = split(direct[u], ds, "\n")
      for (k = 1; k <= nd; k++) {
        d = ds[k]
        if (d == "" || !(d in pos)) continue
        want[d] = 1
        nt = split(tdeps[d], ts, " ")
        for (j = 1; j <= nt; j++) want[ts[j]] = 1
      }
      list = ""
      out = depsdir "/" i
      printf "" > out
      for (j = 1; j < i; j++) {
        d = order[j]
        if (!(d in want)) continue
        list = list (list == "" ? "" : " ") d
        print d " " ((d in f) ? f[d] : "MISSING") > out
      }
      close(out)
      tdeps[u] = list
      print u "\t" i "\t" list > tdeps_out
    }
  }'
(cd "$WORK/deps" && ls | sort -n | tr '\n' '\0' | xargs -0 $SHA) \
  | awk '{ print $2 "\t" $1 }' > "$WORK/deps_fp_by_n"

manifest_existed=1
[ -f "$MANIFEST" ] || manifest_existed=0

# Per-dependency records: replace the lines of the units listed in $1 with "<unit> <dep> <fp>"
# lines taken from their current deps text; drop units no longer in silica.config.
write_dep_records() {
  [ -f "$DEPS_FILE" ] || : > "$DEPS_FILE"
  awk -F'\t' -v units="$WORK/units" -v list="$1" -v tdeps="$WORK/tdeps" -v depsdir="$WORK/deps" \
      -v old="$DEPS_FILE" '
    BEGIN {
      while ((getline l < units) > 0) in_config[l] = 1
      while ((getline l < tdeps) > 0) { split(l, a, "\t"); n_of[a[1]] = a[2] }
      while ((getline l < list) > 0) if (l != "" && l !~ /^#/ && (l in n_of)) redo[l] = 1
      while ((getline l < old) > 0) {
        split(l, a, "\t")
        if ((a[1] in in_config) && !(a[1] in redo)) print l
      }
      for (u in redo) {
        f = depsdir "/" n_of[u]
        while ((getline l < f) > 0) { split(l, b, " "); print u "\t" b[1] "\t" b[2] }
        close(f)
      }
    }' | LC_ALL=C sort > "$DEPS_FILE.tmp"
  mv "$DEPS_FILE.tmp" "$DEPS_FILE"
}

if [ "$CMD" = record ]; then
  # New entries for the units just compiled (they must now have both artifacts), merged over the
  # old manifest; entries for units no longer in silica.config are dropped.
  [ -f "$MANIFEST" ] || : > "$MANIFEST"
  awk -F'\t' -v ctx="$CONTEXT" -v units="$WORK/units" -v rec="$RECORD_UNITS" -v src="$WORK/src_sha" \
      -v tdeps="$WORK/tdeps" -v dfp="$WORK/deps_fp_by_n" -v present="$WORK/present" -v man="$MANIFEST" '
    BEGIN {
      while ((getline l < units) > 0) in_config[l] = 1
      while ((getline l < src) > 0) { split(l, a, "\t"); s[a[1]] = a[2] }
      while ((getline l < dfp) > 0) { split(l, a, "\t"); d_by_n[a[1]] = a[2] }
      while ((getline l < tdeps) > 0) { split(l, a, "\t"); n_of[a[1]] = a[2] }
      while ((getline l < present) > 0) { split(l, a, "\t"); here[a[1]] = 1 }
      while ((getline l < rec) > 0) {
        if (l == "" || l ~ /^#/) continue
        if (!(l in here)) { printf "unit_cache: %s has no .sams/.iface after its batch; not recorded\n", l > "/dev/stderr"; continue }
        new[l] = ctx "\t" s[l] "\t" d_by_n[n_of[l]]
      }
      while ((getline l < man) > 0) {
        split(l, a, "\t")
        if (!(a[1] in in_config) || (a[1] in new)) continue
        print l
      }
      for (u in new) print u "\t" new[u]
    }' | LC_ALL=C sort > "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
  awk -F'\t' -v present="$WORK/present" 'BEGIN { while ((getline l < present) > 0) { split(l, a, "\t"); here[a[1]] = 1 } }
    $0 != "" && $0 !~ /^#/ && ($0 in here)' "$RECORD_UNITS" > "$WORK/recorded"
  write_dep_records "$WORK/recorded"
  exit 0
fi

# Adoption of a build directory from before this script (no manifest): the old mtime rule.
: > "$WORK/adopt"
if [ "$manifest_existed" -eq 0 ] && [ "$CMD" = plan ] && [ -s "$WORK/present" ]; then
  while IFS="$(printf '\t')" read -r u _; do
    base=${u%.silica}
    if [ ! "$u" -nt "$base.sams" ] && [ ! "$u" -nt "$base.iface" ] \
       && [ ! "$COMPILER" -nt "$base.sams" ] && [ ! "$COMPILER" -nt "$base.iface" ]; then
      echo "$u" >> "$WORK/adopt"
    fi
  done < "$WORK/present"
  echo "unit_cache: no $MANIFEST yet; adopting $(wc -l < "$WORK/adopt" | tr -d ' ') unit(s) that the mtime rule keeps"
fi

# Decide each unit, in silica.config order.
#   - undecided: a used unit is undecided, or a used unit is dirty and nothing yet shows this unit
#     must rebuild (its interface may come out unchanged);
#   - dirty: its own inputs changed, or a used unit that is already up to date this round has a
#     different interface from the one this unit was built against (.unit_cache.deps), so it
#     compiles now, after its dirty dependencies in the same batch, instead of a round later;
#   - clean: every used unit is up to date and the deps fingerprint matches.
[ -f "$DEPS_FILE" ] || : > "$DEPS_FILE"
awk -F'\t' -v ctx="$CONTEXT" -v src="$WORK/src_sha" -v tdeps="$WORK/tdeps" -v dfp="$WORK/deps_fp_by_n" \
    -v present="$WORK/present" -v man="$MANIFEST" -v adopt="$WORK/adopt" -v verbose="${UNIT_CACHE_VERBOSE:-0}" \
    -v decisions="$WORK/decisions" -v fp="$WORK/iface_fp" -v recdeps="$DEPS_FILE" '
  BEGIN {
    while ((getline l < fp) > 0) { split(l, a, "\t"); f[a[1]] = a[2] }
    while ((getline l < recdeps) > 0) { split(l, a, "\t"); r[a[1], a[2]] = a[3] }
    while ((getline l < src) > 0) { split(l, a, "\t"); s[a[1]] = a[2] }
    while ((getline l < dfp) > 0) { split(l, a, "\t"); d_by_n[a[1]] = a[2] }
    while ((getline l < present) > 0) { split(l, a, "\t"); here[a[1]] = 1 }
    while ((getline l < adopt) > 0) { m_ctx[l] = ctx; m_src[l] = s[l]; adopted[l] = 1 }
    while ((getline l < man) > 0) {
      split(l, a, "\t"); m_ctx[a[1]] = a[2]; m_src[a[1]] = a[3]; m_dep[a[1]] = a[4]
    }
    nd = nu = ncl = 0
    while ((getline l < tdeps) > 0) {
      split(l, a, "\t"); u = a[1]; n = a[2]; nt = split(a[3], ts, " ")
      # An adopted unit is taken as built against the interfaces on disk now; a dependency that
      # recompiles in a later round with a different interface then makes it dirty as usual.
      if (u in adopted) { m_dep[u] = d_by_n[n]; readopt[u] = 1 }
      hold = 0; dep_dirty = 0; known = 0
      for (j = 1; j <= nt; j++) {
        d = ts[j]
        if (st[d] == "undecided") hold = 1
        else if (st[d] == "dirty") dep_dirty = 1
        else if (!(u in adopted) && ((u, d) in r) && r[u, d] != f[d]) known = 1
      }
      why = ""
      if (!(u in here)) why = "no .sams/.iface"
      else if (!(u in m_ctx)) why = "no manifest entry"
      else if (m_ctx[u] != ctx) why = "host compiler or target changed"
      else if (m_src[u] != s[u]) why = "source changed"
      else if (known) why = "interface of a used unit changed"
      if (hold) st[u] = "undecided"
      else if (why != "") st[u] = "dirty"
      else if (dep_dirty) st[u] = "undecided"
      else if (m_dep[u] != d_by_n[n]) { st[u] = "dirty"; why = "interface of a used unit changed" }
      else st[u] = "clean"
      if (st[u] == "dirty") { nd++; if (verbose == "1" || why != "no .sams/.iface" ) printf "  stale: %s (%s)\n", u, why }
      else if (st[u] == "undecided") nu++
      else ncl++
      print u "\t" st[u] "\t" ((u in readopt) ? m_ctx[u] "\t" m_src[u] "\t" m_dep[u] : "") > decisions
    }
    printf "unit_cache: %d to compile, %d waiting on a used unit, %d up to date\n", nd, nu, ncl
  }'

[ "$CMD" = status ] && exit 0

# Apply: drop the dirty units' artifacts and manifest entries, write adopted entries, list the batch.
awk -F'\t' '$2 == "dirty" { print $1 }' "$WORK/decisions" > "$DIRTY_FILE"
while IFS= read -r u; do
  base=${u%.silica}
  rm -f "$base.sams" "$base.iface" "$base.o"
done < "$DIRTY_FILE"
[ -f "$MANIFEST" ] || : > "$MANIFEST"
awk -F'\t' -v decisions="$WORK/decisions" -v units="$WORK/units" -v man="$MANIFEST" '
  BEGIN {
    while ((getline l < units) > 0) in_config[l] = 1
    while ((getline l < decisions) > 0) {
      split(l, a, "\t")
      if (a[2] == "dirty") drop[a[1]] = 1
      else if (a[3] != "") adopt[a[1]] = a[3] "\t" a[4] "\t" a[5]
    }
    while ((getline l < man) > 0) {
      split(l, a, "\t")
      if (!(a[1] in in_config) || (a[1] in drop) || (a[1] in adopt)) continue
      print l
    }
    for (u in adopt) print u "\t" adopt[u]
  }' | LC_ALL=C sort > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
awk -F'\t' '$2 != "dirty" && $3 != "" { print $1 }' "$WORK/decisions" > "$WORK/adopted_now"
if [ -s "$WORK/adopted_now" ]; then write_dep_records "$WORK/adopted_now"; fi

# A new context (host compiler or target) also invalidates the batch-wide runtime assembly.
if [ -f .unit_cache.context ] && [ "$(cat .unit_cache.context)" != "$CONTEXT" ]; then
  rm -f __silica_runtime.sams __silica_runtime.o
fi
echo "$CONTEXT" > .unit_cache.context
