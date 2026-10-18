"""Verify generated cases against the real compiler and produce golden files.

Success half: compiled in a scratch copy of the target trial directory (so
multi-file areas see their libraries), assembled, linked, run; stdout+exit
must equal the generator's expectation.  The emitted .sams becomes .ascomp.

Failure half: compiled in isolation exactly as error_enforcement_addition's
Makefile does (symlink + one-line silica.config in a temp dir, stdout+stderr
captured to a file); the reported errorCode must equal the intended one and
the capture becomes .golden_fail.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# Repository root is two levels above this file (programmer_tools/train_trial_generator).
ROOT = os.environ.get("SILICA_ROOT") or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TRIALS = ROOT + "/trials"
COMPILER = os.environ.get("SILICA_COMPILER") or ROOT + "/binaries/silica-compiler"
# Scratch work area (never inside the repository).
SCRATCH = os.environ.get("SILICA_GEN_WORK") or os.path.join(tempfile.gettempdir(), "silica_train_gen", "work")
MINV = "26.0"
LDFLAGS = ["-Wl,-e,main", f"-Wl,-macos_version_min,{MINV}"]


def run_compiler(cwd, log=None, timeout=300):
    """Run the compiler in cwd with the exit-75 reclaim loop.  Returns exit code.
    When log is given, stdout+stderr are appended to that file exactly like the
    Makefiles do (shell redirection to a file)."""
    for marker in ("silica.compile.inprogress", "silica.compile.crashed"):
        try:
            os.remove(os.path.join(cwd, marker))
        except OSError:
            pass
    while True:
        if log:
            with open(log, "ab") as fh:
                p = subprocess.run([COMPILER], cwd=cwd, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout)
        else:
            p = subprocess.run([COMPILER], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        if p.returncode in (75, 76):
            continue
        return p.returncode


def compile_failure(stem, src):
    """Isolated compile; returns (code, capture) where code is the errorCode
    found in the capture (or 'OK' / 'NOERR')."""
    tmp = tempfile.mkdtemp(prefix="sf_")
    try:
        path = os.path.join(tmp, stem + ".silica")
        with open(path, "w") as fh:
            fh.write(src)
        with open(os.path.join(tmp, "silica.config"), "w") as fh:
            fh.write(stem + ".silica\n")
        log = os.path.join(tmp, "capture.txt")
        run_compiler(tmp, log=log)
        with open(log, "rb") as fh:
            cap = fh.read().decode("utf-8", "replace")
        m = re.search(r"^errorCode: (E\d{4})", cap, re.M)
        if m:
            return m.group(1), cap
        if "Compilation complete" in cap:
            return "NOERR", cap
        return "UNKNOWN", cap
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def assemble(sams, obj):
    return subprocess.run(["clang", f"-mmacosx-version-min={MINV}", "-c", "-x", "assembler", sams, "-o", obj],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).returncode == 0


def link(objs, exe):
    return subprocess.run(["clang"] + objs + ["-o", exe] + LDFLAGS,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).returncode == 0


def run_exe(exe, cwd, timeout=60):
    try:
        p = subprocess.run([exe], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return p.stdout.decode("utf-8", "replace"), p.returncode
    except subprocess.TimeoutExpired:
        return "<timeout>", -1


def stage_area(area, cases, workdir, extra_files):
    """Copy the trial dir (sources only) into workdir and add candidate sources."""
    src_dir = os.path.join(TRIALS, area)
    if os.path.exists(workdir):
        shutil.rmtree(workdir)
    os.makedirs(workdir)
    for dp, dn, fn in os.walk(src_dir):
        rel = os.path.relpath(dp, src_dir)
        for f in fn:
            if f.endswith(".silica") or f in ("Makefile", "makefile") or f.endswith(".mk") or f.endswith(".meta"):
                d = os.path.join(workdir, rel) if rel != "." else workdir
                os.makedirs(d, exist_ok=True)
                shutil.copy2(os.path.join(dp, f), os.path.join(d, f))
    for c in cases:
        with open(os.path.join(workdir, c["stem"] + ".silica"), "w") as fh:
            fh.write(c["src"])
    for rel, text in extra_files.items():
        p = os.path.join(workdir, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)


def write_config(workdir, area):
    """Mimic each area's silica.config recipe."""
    files = []
    for dp, dn, fn in os.walk(workdir):
        for f in fn:
            if f.endswith(".silica"):
                rel = os.path.relpath(os.path.join(dp, f), workdir)
                if rel.startswith("trial_negative_"):
                    continue
                files.append(rel)
    files.sort()
    if area == "supervisors_addition":
        files.append(ROOT + "/compiler/stdlib/Supervisor.silica")
    with open(os.path.join(workdir, "silica.config"), "w") as fh:
        fh.write("\n".join(files) + "\n")


def verify_area(area, cases, extra_files, jobs=8, runs=1):
    """Compile+run all success candidates of one area.  Returns dict stem ->
    (ok:bool, detail, sams_text)."""
    workdir = os.path.join(SCRATCH, area)
    # pre-check every candidate alone so one bad program cannot sink the batch
    results = {}
    if not any(c.get("info", {}).get("multi") for c in cases):
        pre = verify_failures([(c["stem"], "NOERR", c["src"]) for c in cases], jobs=jobs)
        good = []
        for c in cases:
            got, cap = pre[c["stem"]]
            if got == "NOERR":
                good.append(c)
            else:
                m = re.search(r"^E\d{4}\n\n(.*)$", cap, re.M)
                results[c["stem"]] = (False, f"success candidate does not compile: {got} {m.group(1)[:200] if m else ''}", None)
        cases = good
    stage_area(area, cases, workdir, extra_files)
    write_config(workdir, area)
    if area == "supervisors_addition":
        # the stdlib path is relative to the trial dir two levels below ROOT
        os.makedirs(os.path.join(SCRATCH, "..", "compiler"), exist_ok=True)
    log = os.path.join(workdir, "compile.log")
    rc = run_compiler(workdir, log=log, timeout=3600) if cases else 0
    if rc != 0:
        with open(log) as fh:
            tail = fh.read()[-3000:]
        for c in cases:
            results[c["stem"]] = (False, "batch compile failed rc=%d: %s" % (rc, tail[-600:]), None)
        return results, workdir
    rt = os.path.join(workdir, "__silica_runtime")
    if not assemble(rt + ".sams", rt + ".o"):
        for c in cases:
            results[c["stem"]] = (False, "runtime assemble failed", None)
        return results, workdir
    # library objects for multi-file areas
    lib_objs = []
    for sub in ("lib", "traits"):
        d = os.path.join(workdir, sub)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".sams"):
                    s = os.path.join(d, f)
                    o = s[:-5] + ".o"
                    if assemble(s, o):
                        lib_objs.append(o)
    if area == "supervisors_addition":
        s = os.path.join(workdir, "Supervisor.sams")
        if os.path.exists(s) and assemble(s, s[:-5] + ".o"):
            lib_objs.append(s[:-5] + ".o")

    def one(c):
        stem = c["stem"]
        sams = os.path.join(workdir, stem + ".sams")
        if not os.path.exists(sams):
            return stem, (False, "no .sams emitted", None)
        obj = os.path.join(workdir, stem + ".o")
        exe = os.path.join(workdir, stem)
        if not assemble(sams, obj):
            return stem, (False, "assemble failed", None)
        if not link([obj, rt + ".o"] + lib_objs, exe):
            return stem, (False, "link failed", None)
        expected = c["out"] + str(c["exit"]) + "\n"
        outs = set()
        for _ in range(max(1, runs)):
            out, code = run_exe(exe, workdir)
            outs.add(out + str(code) + "\n")
        if len(outs) != 1:
            return stem, (False, "nondeterministic output", None)
        got = outs.pop()
        if got.split() != expected.split():
            return stem, (False, f"output mismatch: expected {expected!r} got {got!r}", None)
        with open(sams) as fh:
            return stem, (True, "", fh.read())

    if cases:
        with ThreadPoolExecutor(max_workers=jobs) as ex:
            for stem, res in ex.map(one, cases):
                results[stem] = res
    return results, workdir


def verify_failures(cands, jobs=8):
    """cands: list of (stem, code, src).  Returns dict stem -> (got_code, capture)."""
    def one(t):
        stem, code, src = t
        got, cap = compile_failure(stem, src)
        return stem, got, cap
    res = {}
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        for stem, got, cap in ex.map(one, cands):
            res[stem] = (got, cap)
    return res


def process(manifest_path, report_path, out_root, jobs=8, areas=None):
    with open(manifest_path) as fh:
        cases = json.load(fh)
    by_area = {}
    for c in cases:
        if areas and c["area"] not in areas:
            continue
        by_area.setdefault(c["area"], []).append(c)
    report = {"areas": {}, "kept": 0, "dropped_success": [], "dropped_failure": [], "code_counts": {}}
    os.makedirs(out_root, exist_ok=True)
    for area, cs in by_area.items():
        extra = {}
        for c in cs:
            for rel, text in c.get("info", {}).get("extra_files", {}).items():
                extra[rel] = text
        runs = max(c.get("info", {}).get("runs", 1) for c in cs)
        print(f"== {area}: verifying {len(cs)} success candidates", flush=True)
        res, workdir = verify_area(area, cs, extra, jobs=jobs, runs=runs)
        ok_cases = []
        for c in cs:
            ok, detail, sams = res[c["stem"]]
            if not ok:
                report["dropped_success"].append({"stem": c["stem"], "area": area, "why": detail})
            else:
                c["_sams"] = sams
                ok_cases.append(c)
        print(f"   success verified: {len(ok_cases)}/{len(cs)}", flush=True)
        # failure halves: try candidates in order until one matches its intended code
        kept = []
        pending = {c["stem"]: 0 for c in ok_cases}
        active = list(ok_cases)
        while active:
            batch = []
            for c in active:
                i = pending[c["stem"]]
                f = c["fails"][i]
                batch.append((c["stem"], f["code"], f["src"]))
            fres = verify_failures(batch, jobs=jobs)
            nxt = []
            for c in active:
                i = pending[c["stem"]]
                f = c["fails"][i]
                got, cap = fres[c["stem"]]
                if got == f["code"]:
                    c["_golden"] = cap
                    c["_fail"] = f
                    kept.append(c)
                else:
                    report["dropped_failure"].append({"stem": c["stem"], "area": area, "code": f["code"], "got": got, "desc": f["desc"]})
                    pending[c["stem"]] += 1
                    if pending[c["stem"]] < len(c["fails"]):
                        nxt.append(c)
            active = nxt
        print(f"   pairs kept: {len(kept)}/{len(ok_cases)}", flush=True)
        if os.environ.get("M_SHAPE", "1") != "0":
            # item M: the supervisor-actor shape (shape_stage.py), re-verified with this compiler
            import shape_stage
            pairs = [{"stem": c["stem"], "src": c["src"], "scout": c["out"] + str(c["exit"]) + "\n",
                      "fail_src": c["_fail"]["src"], "fail_code": c["_fail"]["code"], "old_golden": None}
                     for c in kept]
            shaped = {r["stem"]: r for r in shape_stage.shape_area(area, pairs, extra)}
            still = []
            for c in kept:
                r = shaped.get(c["stem"])
                if not r or not r["ok"] or "golden" not in r:
                    report["dropped_success"].append({"stem": c["stem"], "area": area,
                                                      "why": "item M shape: " + (r or {}).get("why", r and r.get("fail_left", "?") or "?")})
                    continue
                c["src"], c["_sams"] = r["src"], r["sams"]
                c["_fail"] = dict(c["_fail"], src=r["fail_src"])
                c["_golden"] = r["golden"]
                still.append(c)
            kept = still
            print(f"   pairs in the item M shape: {len(kept)}", flush=True)
        # write outputs
        adir = os.path.join(out_root, area)
        edir = os.path.join(out_root, "error_enforcement_addition")
        os.makedirs(adir, exist_ok=True)
        os.makedirs(edir, exist_ok=True)
        for c in kept:
            stem = c["stem"]
            with open(os.path.join(adir, stem + ".silica"), "w") as fh:
                fh.write(c["src"])
            with open(os.path.join(adir, stem + ".ascomp"), "w") as fh:
                fh.write(c["_sams"])
            with open(os.path.join(adir, stem + ".scout"), "w") as fh:
                fh.write(c["out"] + str(c["exit"]) + "\n")
            for rel, text in c.get("info", {}).get("extra_files", {}).items():
                p = os.path.join(adir, rel)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w") as fh:
                    fh.write(text)
            with open(os.path.join(edir, stem + ".silica"), "w") as fh:
                fh.write(c["_fail"]["src"])
            with open(os.path.join(edir, stem + ".golden_fail"), "w") as fh:
                fh.write(c["_golden"])
            report["code_counts"][c["_fail"]["code"]] = report["code_counts"].get(c["_fail"]["code"], 0) + 1
        report["areas"][area] = {"candidates": len(cs), "success_ok": len(ok_cases), "pairs": len(kept)}
        report["kept"] += len(kept)
        with open(report_path, "w") as fh:
            json.dump(report, fh, indent=1)
    return report


if __name__ == "__main__":
    manifest, report, out_root = sys.argv[1:4]
    areas = sys.argv[4].split(",") if len(sys.argv) > 4 else None
    r = process(manifest, report, out_root, areas=areas)
    print(json.dumps({k: v for k, v in r.items() if k in ("areas", "kept", "code_counts")}, indent=1))
    print("dropped success:", len(r["dropped_success"]), "dropped failure attempts:", len(r["dropped_failure"]))
