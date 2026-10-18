"""Item M stage: put verified train pairs in the supervisor-actor shape (actor_memory_budget_plan.md).

A success program's `main` keeps its name and header; its body travels as a function literal to the
shared worker in trials/lib_trial_support/ (see programmer_tools/trial_shape_m/README.md). The
failure twin gets exactly the same edit (same form, type and literal), so the pair still differs only
by the deliberate mistake. Every `print_bool` becomes `print_boolean` first.

Used two ways:
  * on freshly generated pairs: pipeline.py --shape runs it on its output tree before install;
  * on the installed pairs: `python3 shape_stage.py --installed [areas]` reads them from trials/,
    reshapes and re-verifies them, and writes the results into an output tree that install.py
    copies back (`python3 shape_stage.py --installed OUT [area,...]`, then `install.py OUT`).

Verification, with the compiler of the day (SILICA_COMPILER):
  * success: the area is staged with every shaped program, the trial-support modules it uses and
    Supervisor; compiled as one batch; each program assembled, linked with its support module, run;
    stdout + exit status must equal its .scout;
  * failure: compiled alone with its support module and Supervisor, exactly as the
    error-enforcement Makefile does; the error code must equal the twin's intended code (from its
    first-line comment or the old golden) and, when an old golden exists, the position must be the
    old one carried through the edits (the same construct).
Form C (a non-int64 main with a computed result) ends with the value main returns today as a
literal; that value is learned by a probe build of the same staged area whose main prints it.
"""
import json
import os
import re
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "trial_shape_m"))
import pipeline  # noqa: E402
import shape  # noqa: E402  (trial_shape_m)
import errcheck  # noqa: E402  (trial_shape_m)

SUPPORT_DIR = os.path.join(pipeline.ROOT, "trials", "lib_trial_support")
SUPERVISOR = os.path.join(pipeline.ROOT, "compiler", "stdlib", "Supervisor.silica")
PRINT_FN = dict([(t, "print_" + t) for t in shape.INT_TYPES + shape.FLOAT_TYPES]
                + [("atom", "print_atom"), ("boolean", "print_boolean")])
MARK = "@@M_PROBE "
PLACEHOLDER = dict([(t, "0") for t in shape.INT_TYPES] + [(t, "0.0") for t in shape.FLOAT_TYPES]
                   + [("atom", ":ok"), ("boolean", "true"), ("string", '""')])


def probe_src(src):
    m = shape.ss.mask(src)
    pos, f = shape.locate_main(src, m)
    t = shape.binding_type(f.ret_type)
    new = src[:pos] + "trial_main" + src[pos + 4:]
    if not new.endswith("\n"):
        new += "\n"
    return new + ("\nfn main() -> %s {\n    sequence proc[device_io]\n        value: %s <- trial_main();\n"
                  "        println(\"\");\n        print_string(\"%s\");\n        _: atom <- %s(value);\n"
                  "        println(\"\")\n    produces\n        pure value\n    end\n}\n") % (t, t, MARK, PRINT_FN[t])


def stage_and_build(area, cases, tag, extra_files):
    """Stage `cases` (dicts stem/src) in a scratch copy of the area plus the support modules they use;
    compile; return (workdir, {stem: exe path or None}, compile_ok)."""
    workdir = os.path.join(pipeline.SCRATCH, "shape_" + tag, area)
    pipeline.stage_area(area, cases, workdir, extra_files)
    sd = os.path.join(workdir, ".trial_stdlib")
    shutil.rmtree(sd, ignore_errors=True)
    mods = set()
    for dp, dn, fn in os.walk(workdir):
        for f in fn:
            if f.endswith(".silica"):
                mods |= set(re.findall(r"(?m)^use (trial_[a-z0-9_]+);", open(os.path.join(dp, f), errors="replace").read()))
    mods = sorted(mods)
    pipeline.write_config(workdir, area)
    os.makedirs(sd, exist_ok=True)
    names = list(mods)
    have_sup = any(ln.rstrip().endswith("Supervisor.silica") for ln in open(os.path.join(workdir, "silica.config")))
    if mods and not have_sup:   # the area may list the trait already (stdlib path, or its own lib/ copy)
        names = ["Supervisor"] + names
        os.symlink(SUPERVISOR, os.path.join(sd, "Supervisor.silica"))
    for mod in mods:
        os.symlink(os.path.join(SUPPORT_DIR, mod + ".silica"), os.path.join(sd, mod + ".silica"))
    with open(os.path.join(workdir, "silica.config"), "a") as fh:
        for x in names:
            fh.write(".trial_stdlib/%s.silica\n" % x)
    rc = pipeline.run_compiler(workdir, log=os.path.join(workdir, "compile.log"), timeout=3600)
    if rc != 0:
        return workdir, {}, False
    rt = os.path.join(workdir, "__silica_runtime")
    pipeline.assemble(rt + ".sams", rt + ".o")
    lib_objs = []
    for sub in ("lib", "traits"):
        d = os.path.join(workdir, sub)
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".sams") and pipeline.assemble(os.path.join(d, f), os.path.join(d, f[:-5] + ".o")):
                    lib_objs.append(os.path.join(d, f[:-5] + ".o"))
    for mod in mods:
        pipeline.assemble(os.path.join(sd, mod + ".sams"), os.path.join(sd, mod + ".o"))

    def one(c):
        stem = c["stem"]
        sams = os.path.join(workdir, stem + ".sams")
        obj, exe = sams[:-5] + ".o", sams[:-5]
        if not (os.path.exists(sams) and pipeline.assemble(sams, obj)):
            return stem, None
        sup = [os.path.join(sd, m + ".o") for m in re.findall(r"(?m)^use (trial_[a-z0-9_]+);", c["src"])]
        return stem, (exe if pipeline.link([obj, rt + ".o"] + sup + lib_objs, exe) else None)

    with ThreadPoolExecutor(max_workers=8) as ex:
        exes = dict(ex.map(one, cases))
    return workdir, exes, True


def norm(s):
    return [re.sub(r"\s+", "", ln) for ln in s.splitlines() if ln.strip()]


def shape_area(area, pairs, extra_files=None, log=print):
    """pairs: list of dicts {stem, src, scout, fail_src, fail_code, old_golden (or None)}.
    Returns list of results {stem, ok, why, src, fail_src, golden, form}."""
    extra_files = extra_files or {}
    out = {}
    plans = {}
    # 1. forms; probe the form-C ones
    need_probe = []
    for p in pairs:
        src, _ = shape.rename_builtins(p["src"])
        p["_src"] = src
        if re.search(r"(?m)^\s*impl\s+\w+\s+for\s+Supervisor\s*;", src):
            out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "success: implements Supervisor itself"}
            continue
        if re.search(r"(?m)^\[silica\] (fault|abort)", p["scout"]) and not re.search(r"\bspawn", src):
            out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "success: expects main's own fatal banner"}
            continue
        if re.search(r"(?m)^(language_error|badarith|case_clause|badmatch|function_clause)\s*$", p["scout"]) \
                and p["scout"].rstrip().endswith("\n1"):
            out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "success: expects a failure raised in main"}
            continue
        try:
            plans[p["stem"]] = shape.choose_form(src)
        except shape.ShapeError as e:
            out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "success: " + str(e)}
            continue
        if plans[p["stem"]][0] == "C":
            need_probe.append(p)
    if need_probe:
        _, exes, ok = stage_and_build(area, [{"stem": p["stem"], "src": probe_src(p["_src"])} for p in need_probe],
                                      "probe", extra_files)
        for p in need_probe:
            exe = exes.get(p["stem"]) if ok else None
            got = pipeline.run_exe(exe, os.path.dirname(exe))[0] if exe else ""
            k = got.rfind("\n" + MARK)
            val = got[k + 1 + len(MARK):].split("\n", 1)[0].strip() if k >= 0 else None
            if val is None or not shape.LITERAL_RE.fullmatch(val):
                out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "probe gave no literal (%r)" % val}
                plans.pop(p["stem"], None)
                continue
            f, t, _ = plans[p["stem"]]
            plans[p["stem"]] = (f, t, val)
    # 2. reshape successes, verify them in one staged batch
    shaped = []
    for p in pairs:
        if p["stem"] not in plans:
            continue
        f, t, lit = plans[p["stem"]]
        p["_shaped"], _ = shape.reshape(p["_src"], f, t, lit)
        shaped.append({"stem": p["stem"], "src": p["_shaped"]})
    workdir, exes, ok = stage_and_build(area, shaped, "verify", extra_files)
    if not ok:
        log("   %s: shaped batch did not compile; see %s/compile.log" % (area, workdir))
    mismatch = []
    for p in pairs:
        if p["stem"] not in plans:
            continue
        exe = exes.get(p["stem"]) if ok else None
        if not exe:
            out[p["stem"]] = {"stem": p["stem"], "ok": False, "why": "shaped success did not build"}
            continue
        got, code = pipeline.run_exe(exe, workdir)
        p["_got"] = got + str(code) + "\n"
        if norm(p["_got"]) != norm(p["scout"]):
            mismatch.append(p)
    # A shaped program whose output differs from its .scout is kept only when the program as it was
    # (before the shape) gives exactly the same output with this compiler: the shape changed nothing,
    # the .scout was already stale (reported, not rewritten).
    stale = set()
    if mismatch:
        owork, oexes, ook = stage_and_build(area, [{"stem": p["stem"], "src": p["_src"]} for p in mismatch],
                                            "orig", extra_files)
        for p in mismatch:
            oexe = oexes.get(p["stem"]) if ook else None
            if oexe:
                ogot, ocode = pipeline.run_exe(oexe, owork)
                if norm(ogot + str(ocode) + "\n") == norm(p["_got"]):
                    stale.add(p["stem"])
                    continue
            out[p["stem"]] = {"stem": p["stem"], "ok": False,
                              "why": "shaped success output %r != scout" % p["_got"][-120:]}
    for p in pairs:
        if p["stem"] not in plans or p["stem"] in out:
            continue
        # the run matched its .scout, so the emitted assembly is its .ascomp (Lee's rule); a stale
        # .scout gets no .ascomp refresh
        sams = None if p["stem"] in stale else open(os.path.join(workdir, p["stem"] + ".sams")).read()
        out[p["stem"]] = {"stem": p["stem"], "ok": True, "src": p["_shaped"], "form": plans[p["stem"]][0],
                          "sams": sams, "scout_stale": p["stem"] in stale}

    # 3. failure twins: the success twin's plan (placeholder-free, so the pair differs only by the mistake)
    def fail_one(p):
        r = out.get(p["stem"])
        if not r or not r["ok"] or p.get("fail_src") is None:
            return p["stem"], None
        f, t, lit = plans[p["stem"]]
        old = p["fail_src"]
        t1, e1 = shape.rename_builtins(old)
        stages = [(old, t1, e1)]
        try:
            t2, e2 = shape.reshape(t1, f, t, lit)
            stages.append((t1, t2, e2))
        except shape.ShapeError as e:
            return p["stem"], {"ok": False, "why": "failure: " + str(e)}
        gold = errcheck.compile_alone(pipeline.COMPILER, p["stem"] + ".silica", t2)
        nm = errcheck.meta(gold) or {}
        if nm.get("errorCode") != p["fail_code"]:
            return p["stem"], {"ok": False, "why": "failure code %s != %s" % (nm.get("errorCode"), p["fail_code"])}
        if p.get("old_golden"):
            om = errcheck.meta(p["old_golden"]) or {}
            try:
                exp = shape.map_through(stages, int(om["line"]), int(om["column"]), int(om["offset"]))
            except (KeyError, ValueError):
                exp = None
            got = (int(nm["line"]), int(nm["column"]), int(nm["offset"]))
            if exp is None or tuple(exp) != got:
                nb, ob = t2.encode(), old.encode()
                oo = int(om.get("offset", -1))
                brace = (ob[oo:oo + 1] == b"}" and old[len(ob[:oo].decode("utf-8", "ignore")):].strip() == "}"
                         and nb[got[2]:got[2] + 2] == b"})")
                if not brace:
                    return p["stem"], {"ok": False, "why": "failure position %s, expected %s" % (got, exp)}
        return p["stem"], {"ok": True, "fail_src": t2, "golden": gold}

    with ThreadPoolExecutor(max_workers=8) as ex:
        for stem, fr in ex.map(fail_one, pairs):
            if fr is None:
                continue
            if fr["ok"]:
                out[stem].update(fail_src=fr["fail_src"], golden=fr["golden"])
            else:
                # the success twin is still shaped; its failure twin stays as it was
                out[stem]["fail_left"] = fr["why"]
    return [out[p["stem"]] for p in pairs if p["stem"] in out]


def installed_pairs(area):
    """The installed train pairs of one area, read from trials/."""
    adir = os.path.join(pipeline.TRIALS, area)
    edir = os.path.join(pipeline.TRIALS, "error_enforcement_addition")
    pairs = []
    for f in sorted(os.listdir(adir)):
        if not (f.startswith("train_") and f.endswith(".silica")):
            continue
        stem = f[:-7]
        if not os.path.exists(os.path.join(adir, stem + ".scout")):
            continue
        src = open(os.path.join(adir, f)).read()
        if re.search(r"(?m)^use trial_(support|wait)_", src):
            continue   # already in the shape
        p = {"stem": stem, "src": src,
             "scout": open(os.path.join(adir, stem + ".scout")).read(),
             "fail_src": None, "fail_code": None, "old_golden": None}
        fs = os.path.join(edir, f)
        if os.path.exists(fs) and os.path.exists(fs[:-7] + ".golden_fail"):
            p["fail_src"] = open(fs).read()
            p["old_golden"] = open(fs[:-7] + ".golden_fail").read()
            p["fail_code"] = (errcheck.meta(p["old_golden"]) or {}).get("errorCode")
        pairs.append(p)
    return pairs


def write_results(out_root, area, results, scouts):
    adir = os.path.join(out_root, area)
    edir = os.path.join(out_root, "error_enforcement_addition")
    os.makedirs(adir, exist_ok=True)
    os.makedirs(edir, exist_ok=True)
    n = 0
    for r in results:
        if not r["ok"]:
            continue
        with open(os.path.join(adir, r["stem"] + ".silica"), "w") as fh:
            fh.write(r["src"])
        if r.get("sams") is not None:
            with open(os.path.join(adir, r["stem"] + ".ascomp"), "w") as fh:
                fh.write(r["sams"])
        if "golden" in r:
            with open(os.path.join(edir, r["stem"] + ".silica"), "w") as fh:
                fh.write(r["fail_src"])
            with open(os.path.join(edir, r["stem"] + ".golden_fail"), "w") as fh:
                fh.write(r["golden"])
        n += 1
    return n


def main():
    args = sys.argv[1:]
    if not args or args[0] != "--installed":
        raise SystemExit(__doc__)
    out_root = args[1]
    areas = args[2].split(",") if len(args) > 2 else sorted(
        d for d in os.listdir(pipeline.TRIALS)
        if os.path.isdir(os.path.join(pipeline.TRIALS, d)) and any(
            f.startswith("train_") and f.endswith(".scout") for f in os.listdir(os.path.join(pipeline.TRIALS, d))))
    report = {}
    for area in areas:
        pairs = installed_pairs(area)
        print("== %s: %d installed pairs" % (area, len(pairs)), flush=True)
        res = shape_area(area, pairs)
        n = write_results(out_root, area, res, None)
        bad = [r for r in res if not r["ok"]]
        forms = {}
        for r in res:
            if r["ok"]:
                forms[r["form"]] = forms.get(r["form"], 0) + 1
        report[area] = {"pairs": len(pairs), "shaped": n, "forms": forms,
                        "left": [(r["stem"], r["why"]) for r in bad],
                        "failure_twin_left": [(r["stem"], r["fail_left"]) for r in res if r.get("fail_left")],
                        "scout_stale": [r["stem"] for r in res if r.get("scout_stale")]}
        print("   shaped %d, left %d, failure twins left %d, stale .scout (output unchanged by the shape) %d, forms %s" % (
            n, len(bad), len(report[area]["failure_twin_left"]), len(report[area]["scout_stale"]), forms), flush=True)
        with open(os.path.join(out_root, "shape_report.json"), "w") as fh:
            json.dump(report, fh, indent=1)


if __name__ == "__main__":
    main()
