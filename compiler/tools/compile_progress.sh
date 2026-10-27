#!/bin/sh
# Turn the compiler's per-unit stage log into a progress bar.
#
# The assembly loop feeds one silica-compiler process's stdout here. Each process
# compiles one unit, prints the stages ("Lexing...", "Type checking...", ...), then
# exits 75 so the OS can reclaim the heap. The makefile knows how many units this
# batch will compile and passes that as SILICA_PROGRESS_TOTAL.
#
# A terminal (and no CI) rewrites a single line. The next unit's process overwrites
# that same line. CI, and any run whose stdout is not a terminal, prints one new
# line each time the stage changes so the log keeps every update.
#
# A line that is not one of those stage announcements is a diagnostic. The bar
# stops, a line names the unit and stage, and every line after that is printed
# unchanged, including the blank lines inside a compiler error.
#
# SILICA_PROGRESS=off copies the compiler log through unchanged.
# SILICA_PROGRESS_MODE=tty|line forces the style.
set -u

if [ "${SILICA_PROGRESS:-}" = "off" ]; then
	cat
	exit 0
fi

mode=${SILICA_PROGRESS_MODE:-auto}
if [ "$mode" = "auto" ]; then
	if [ -n "${GITHUB_ACTIONS:-}" ] || [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
		mode=line
	elif [ -t 1 ]; then
		mode=tty
	else
		mode=line
	fi
fi
case $mode in
	tty|line) ;;
	*) mode=line ;;
esac

total=${SILICA_PROGRESS_TOTAL:-0}
case $total in
	''|*[!0-9]*) total=0 ;;
esac

cols=80
if [ "$mode" = "tty" ]; then
	if [ -n "${COLUMNS:-}" ]; then
		case $COLUMNS in
			*[!0-9]*|'') ;;
			*) cols=$COLUMNS ;;
		esac
	elif [ -r /dev/tty ]; then
		c=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
		case $c in
			*[!0-9]*|'') ;;
			*) cols=$c ;;
		esac
	fi
fi

# awk so each update is flushed. A shell printf of a carriage return sits in the
# stdio buffer until a newline, which is the whole screen we are trying not to fill.
exec awk -v mode="$mode" -v total="$total" -v cols="$cols" '
function startswith(s, p) {
	return index(s, p) == 1
}
function endswith(s, p) {
	return length(s) >= length(p) && substr(s, length(s) - length(p) + 1) == p
}
function emit_nl() {
	printf "\n"
	fflush()
}
function passthrough(s) {
	if (dirty) {
		emit_nl()
		dirty = 0
	}
	printf "%s\n", s
	last_msg = ""
	fflush()
}
function context() {
	where = file
	st = stage
	l = left
	cur = 0
	if (where == "") where = "(no unit yet)"
	if (st == "") st = phase
	if (st == "") st = "(no stage yet)"
	if (total > 0) {
		if (l > total) l = total
		if (l < 0) l = 0
		cur = total - l + 1
		if (cur > total) cur = total
		if (cur < 1) cur = 1
		printf "%s (%s, unit %d/%d):\n", where, st, cur, total
	} else {
		printf "%s (%s):\n", where, st
	}
	fflush()
}
# A diagnostic ends the bar for this process. Later lines are the compiler
# text, blanks included, so a multi-line error stays complete.
function emit_raw(s) {
	if (!raw) {
		if (dirty) {
			emit_nl()
			dirty = 0
		}
		context()
		raw = 1
		last_msg = ""
	}
	printf "%s\n", s
	fflush()
}
function draw() {
	l = left
	cur = 0
	done = 0
	filled = 0
	empty = 0
	pct = 0
	hashes = ""
	dashes = ""
	msg = ""
	i = 0
	if (total == 0 || file == "") {
		return
	}
	if (l > total) l = total
	if (l < 0) l = 0
	base = total - l
	cur = base + 1
	if (cur > total) cur = total
	if (cur < 1) cur = 1
	done = base
	if (finished) done = base + 1
	if (done > total) done = total
	if (done < 0) done = 0
	filled = int(bar_width * done / total)
	empty = bar_width - filled
	for (i = 0; i < filled; i++) hashes = hashes "#"
	for (i = 0; i < empty; i++) dashes = dashes "-"
	pct = int(100 * done / total)
	msg = "[" hashes dashes "] " cur "/" total " " pct "%  " file "  " stage
	if (msg == last_msg) return
	last_msg = msg
	if (mode == "tty") {
		if (length(msg) > cols - 1) msg = substr(msg, 1, cols - 1)
		printf "\r\033[K%s", msg
		dirty = 1
	} else {
		printf "%s\n", msg
		dirty = 0
	}
	fflush()
}
function take_count(kind, s) {
	if (s ~ /^[0-9]+$/) {
		if (kind == "left") {
			left = s + 0
			if (total == 0) total = left
			finished = 0
		} else if (total == 0) {
			total = s + 0
		}
	} else {
		emit_raw(s)
	}
}
BEGIN {
	bar_width = 24
	total += 0
	cols += 0
	if (cols < 20) cols = 20
	left = total
	file = ""
	stage = ""
	phase = ""
	expect = ""
	finished = 0
	dirty = 0
	raw = 0
	last_msg = ""
}
{
	if (raw) {
		printf "%s\n", $0
		fflush()
		next
	}
	if (expect == "left" || expect == "files") {
		kind = expect
		expect = ""
		take_count(kind, $0)
		next
	}
	if (expect == "path") {
		expect = ""
		if (!endswith($0, "...")) {
			emit_raw($0)
			next
		}
		file = $0
		if (endswith(file, "...")) file = substr(file, 1, length(file) - 3)
		stage = phase
		finished = 0
		draw()
		next
	}
	if ($0 == "") {
		if (file == "") passthrough($0)
		next
	}
	if (startswith($0, "Resuming compile order; units left:")) {
		expect = "left"
		next
	}
	if (startswith($0, "Files to compile:")) {
		expect = "files"
		next
	}
	if ($0 == "Parsing " || $0 == "Parsing") {
		expect = "path"
		phase = "Parsing"
		next
	}
	if ($0 == "Compiling " || $0 == "Compiling") {
		expect = "path"
		phase = "Compiling"
		next
	}
	if (startswith($0, "Unit compiled; exiting to reclaim memory before next unit...") ||
	    startswith($0, "Compile order ready; exiting to reclaim memory before unit compiles...") ||
	    $0 == "  (reclaiming memory; continuing next unit)") {
		next
	}
	if (startswith($0, "Finished compiling ")) {
		finished = 1
		stage = "finished"
		draw()
		next
	}
	if (startswith($0, "Compilation complete.")) {
		finished = 1
		stage = "finished"
		draw()
		passthrough($0)
		next
	}
	if (startswith($0, "  ") && endswith($0, "...")) {
		if (file != "") {
			stage = substr($0, 3)
			if (endswith(stage, "...")) stage = substr(stage, 1, length(stage) - 3)
			draw()
		} else {
			emit_raw($0)
		}
		next
	}
	emit_raw($0)
}
'
