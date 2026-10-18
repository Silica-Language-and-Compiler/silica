#!/usr/bin/env python3
"""Convert single-file error trials and re-derive their .golden_fail from the real compiler.

    errcheck.py <error_dir> <compiler> <work_dir> [--train only|skip|all] [--jobs N] [--install]
                [--files LIST] [--plans plans.json]

For each <stem>.silica with a <stem>.golden_fail directly in <error_dir>:
  1. shape.rename_builtins (print_bool -> print_boolean), then convert.plan + shape.reshape (form
     A/B/C/W), keeping both edit lists. A trial left in its old shape gets the rename only.
     --plans maps stem -> [form, T, literal] to impose a plan (the train generator passes the
     success twin's plan to its failure twin).
  2. compile it alone exactly as error_enforcement_addition/Makefile does (a scratch directory with
     the file, the trial-support module it uses and Supervisor.silica, a silica.config naming them
     in that order; the compiler re-run while it exits 75);
  3. compare the new output's metadata with the old golden's:
       same / same_msgdiff  same errorCode, and line/column/offset equal the old position carried
                            through the edits (shape.map_through): the same construct is reported;
                            same_msgdiff when only the message wording changed
       same_closing_brace   an error found at main's closing brace (E1051, a sequence without
                            `end`) now found at the closing brace of the literal holding main's body
       unchanged            neither the source nor the golden changes
       moved / code / nometa  a different position / errorCode / no metadata block: not installed
       left                 no form fits and nothing to rename
Writes <work_dir>/errcheck.tsv and, per trial, <work_dir>/out/<stem>.silica and .golden_fail.
--install copies the verified ones over <error_dir>/<stem>.silica and .golden_fail.
"""

import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convert  # noqa: E402
import inventory  # noqa: E402
import shape  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SUPERVISOR = os.path.join(ROOT, 'compiler', 'stdlib', 'Supervisor.silica')
SUPPORT_DIR = os.path.join(ROOT, 'trials', 'lib_trial_support')
META_RE = re.compile(r'<!-- SILICA-ERROR-METADATA\n(.*?)-->', re.S)
GOOD = ('same', 'same_msgdiff', 'same_closing_brace')


def meta(text):
    mo = META_RE.search(text)
    if not mo:
        return None
    d = {}
    for ln in mo.group(1).splitlines():
        if ':' in ln:
            k, v = ln.split(':', 1)
            d[k.strip()] = v.strip()
    return d


def message(text):
    """The human message: the lines between the error code line and 'See specification'."""
    mo = re.search(r'\n(E\d{4})\n\n(.*?)\n(?:See specification|<!--)', text, re.S)
    return mo.group(2).strip() if mo else None


def compile_alone(compiler, name, text):
    """Compile `text` as <name> alone, with the trial-support module it uses and Supervisor, in the
    order error_enforcement_addition/Makefile ($(TRIAL_SUPPORT_IN_TMP)) lists them."""
    d = tempfile.mkdtemp(prefix='m_err_')
    try:
        open(os.path.join(d, name), 'w', encoding='utf-8').write(text)
        cfg = name + '\n'
        for mod in re.findall(r'(?m)^use (trial_[a-z0-9_]*);', text):
            os.symlink(os.path.join(SUPPORT_DIR, mod + '.silica'), os.path.join(d, mod + '.silica'))
            if not os.path.exists(os.path.join(d, 'Supervisor.silica')):
                os.symlink(SUPERVISOR, os.path.join(d, 'Supervisor.silica'))
            cfg += mod + '.silica\nSupervisor.silica\n'
        open(os.path.join(d, 'silica.config'), 'w').write(cfg)
        out = b''
        for _ in range(50):
            p = subprocess.run([compiler], cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=900)
            out += p.stdout
            if p.returncode not in (75, 76):
                break
        return out.decode('utf-8', errors='replace')
    finally:
        shutil.rmtree(d, ignore_errors=True)


def derive(path, compiler, outdir, pats, plan=None):
    """Convert one error trial; return (stem, status, detail, code)."""
    stem = os.path.basename(path)[:-len('.silica')]
    old_text = open(path, encoding='utf-8').read()
    old_gold = open(path[:-len('.silica')] + '.golden_fail', encoding='utf-8', errors='replace').read()
    text1, edits1 = shape.rename_builtins(old_text)
    stages = [(old_text, text1, edits1)]
    form = '-'
    why = ''
    try:
        if plan is None:
            row = inventory.classify(path)
            key = os.path.join(os.path.basename(os.path.dirname(path)), os.path.basename(path))
            plan = convert.plan(row, key, pats)
        form, t, lit = plan
        text2, edits2 = shape.reshape(text1, form, t, lit)
        stages.append((text1, text2, edits2))
    except shape.ShapeError as e:
        why = str(e)
        text2 = text1
        if text2 == old_text:
            return stem, 'left', why, ''
    new_gold = compile_alone(compiler, stem + '.silica', text2)
    open(os.path.join(outdir, stem + '.silica'), 'w', encoding='utf-8').write(text2)
    open(os.path.join(outdir, stem + '.golden_fail'), 'w', encoding='utf-8').write(new_gold)
    if new_gold == old_gold and text2 == old_text:
        return stem, 'unchanged', why, ''
    om, nm = meta(old_gold), meta(new_gold)
    if not om or not nm:
        return stem, 'nometa', form, ''
    if om.get('errorCode') != nm.get('errorCode'):
        return stem, 'code', '%s %s -> %s' % (form, om.get('errorCode'), nm.get('errorCode')), nm.get('file', '')
    try:
        exp = shape.map_through(stages, int(om['line']), int(om['column']), int(om['offset']))
    except (KeyError, ValueError):
        exp = None
    got = (int(nm['line']), int(nm['column']), int(nm['offset'])) if nm.get('offset', '').isdigit() else None
    msg_same = message(old_gold) == message(new_gold)
    detail = '%s old %s:%s@%s exp %s got %s%s%s' % (
        form, om.get('line'), om.get('column'), om.get('offset'), exp, got,
        '' if msg_same else ' (message text differs)', (' [rename only: %s]' % why) if why else '')
    if exp is not None and got == tuple(exp) and nm.get('file') == om.get('file'):
        return stem, 'same' if msg_same else 'same_msgdiff', detail, nm.get('errorCode')
    ob = old_text.encode('utf-8')
    nb = text2.encode('utf-8')
    oo = int(om['offset'])
    if got and msg_same and ob[oo:oo + 1] == b'}' \
            and old_text[len(ob[:oo].decode('utf-8', 'ignore')):].strip() == '}' \
            and nb[got[2]:got[2] + 2] == b'})':
        return stem, 'same_closing_brace', detail, nm.get('errorCode')
    return stem, 'moved', detail, nm.get('errorCode')


def _one(args):
    path, compiler, outdir, pats, plan = args
    return derive(path, compiler, outdir, pats, plan)


def run(edir, compiler, work, train='all', jobs=None, files=None, plans=None, install=False):
    pats = convert.exclusions()
    outdir = os.path.join(work, 'out')
    os.makedirs(outdir, exist_ok=True)
    todo = []
    for f in sorted(os.listdir(edir)):
        if not f.endswith('.silica'):
            continue
        stem = f[:-len('.silica')]
        if not os.path.exists(os.path.join(edir, stem + '.golden_fail')):
            continue
        is_train = f.startswith('train_')
        if (train == 'only' and not is_train) or (train == 'skip' and is_train):
            continue
        if files is not None and stem not in files:
            continue
        plan = tuple(plans[stem]) if plans and stem in plans else None
        todo.append((os.path.join(edir, f), compiler, outdir, pats, plan))
    with cf.ThreadPoolExecutor(jobs or os.cpu_count()) as ex:
        results = list(ex.map(_one, todo))
    with open(os.path.join(work, 'errcheck.tsv'), 'w') as o:
        for r in results:
            o.write('\t'.join(str(x) for x in r) + '\n')
    print(Counter(r[1] for r in results))
    if install:
        n = 0
        for stem, status, _, _ in results:
            if status in GOOD:
                shutil.copyfile(os.path.join(outdir, stem + '.silica'), os.path.join(edir, stem + '.silica'))
                shutil.copyfile(os.path.join(outdir, stem + '.golden_fail'), os.path.join(edir, stem + '.golden_fail'))
                n += 1
        print('installed', n)
    return results


def main():
    args = sys.argv[1:]
    edir, compiler, work = args[0], args[1], args[2]
    train = args[args.index('--train') + 1] if '--train' in args else 'all'
    jobs = int(args[args.index('--jobs') + 1]) if '--jobs' in args else None
    files = set(open(args[args.index('--files') + 1]).read().split()) if '--files' in args else None
    plans = json.load(open(args[args.index('--plans') + 1])) if '--plans' in args else None
    run(edir, compiler, work, train, jobs, files, plans, '--install' in args)


if __name__ == '__main__':
    main()
