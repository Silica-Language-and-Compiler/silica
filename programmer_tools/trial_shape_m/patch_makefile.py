#!/usr/bin/env python3
"""Patch a suite Makefile for the trial-support modules (item M).

    patch_makefile.py <Makefile> [...]

Three edits, each applied where its pattern occurs (the report says how many times):
  config  `... LC_ALL=C sort > silica.config`  ->  `... > silica.config && $(TRIAL_SUPPORT_CONFIG)`
          (an earlier pilot's $(TRIAL_SUPERVISOR_CONFIG) is renamed)
  objs    after `[ -f "__silica_runtime.o" ] && runtime_obj="__silica_runtime.o"; \\` the trial's
          support object joins the runtime object, so every existing link line links it
  asm     `$(TRIAL_SUPPORT_ASSEMBLE); \\` before every `for o in *.o; do \\` link loop
Single-file error rule: after `echo "$$base.silica" > "$$tmpdir/silica.config"; \\` the
$(call TRIAL_SUPPORT_IN_TMP,...) line (an earlier pilot's TRIAL_SUPERVISOR_IN_TMP is renamed).
A Makefile none of these fit must be patched by hand; the report says so.
"""

import re
import sys


def patch(text):
    n = {}
    text, n['rename'] = re.subn(r'TRIAL_SUPERVISOR_CONFIG', 'TRIAL_SUPPORT_CONFIG', text)
    text, k = re.subn(r'TRIAL_SUPERVISOR_IN_TMP', 'TRIAL_SUPPORT_IN_TMP', text)
    n['rename'] += k
    if 'TRIAL_SUPPORT_IN_TMP' in text:   # a single-file (error) suite: no batch silica.config
        return text, n
    if 'TRIAL_SUPPORT_CONFIG' not in text:
        # every recipe line that writes silica.config (not a single-file $$tmpdir config)
        text, n['config'] = re.subn(r'(?m)^(\t[^\n]*[^>]> ?"?silica\.config"?)[ \t]*$',
                                    lambda mo: mo.group(1) if '$$tmpdir' in mo.group(1) or 'echo' in mo.group(1)
                                    else mo.group(1) + ' && $(TRIAL_SUPPORT_CONFIG)', text)
        text = re.sub(r'(?m)^(\t[^\n]*> "\$\(THIS_DIR\)silica\.config")[ \t]*$',
                      r'\1 && cd "$(THIS_DIR)" && $(TRIAL_SUPPORT_CONFIG)', text)
        n['config'] = text.count('$(TRIAL_SUPPORT_CONFIG)')
    if '.trial_stdlib/' not in text:
        # loops over silica.config lines must not treat the support links as trials
        text, n['loops'] = re.subn(r"(grep -v '\^#' silica\.config 2>/dev/null \| grep -v '\^\$\$')",
                                   r"\1 | grep -v '^\\.trial_stdlib/'", text)
    if 'TRIAL_SUPPORT_OBJ' not in text:
        text, k = re.subn(
            r'(\n(\s*)\[ -f "__silica_runtime\.o" \] && rt_one="__silica_runtime\.o"; \\\n)',
            r'\1\2rt_one="$$rt_one $(call TRIAL_SUPPORT_OBJ,$$stem.silica)"; \\\n', text)
        n['objs_rt_one'] = k
        text, n['objs'] = re.subn(
            r'(\n(\s*)\[ -f "?__silica_runtime\.o"? \] && runtime_obj="?__silica_runtime\.o"?; \\\n)',
            r'\1\2runtime_obj="$$runtime_obj $(call TRIAL_SUPPORT_OBJ,$$base.silica)"; \\\n', text)
    if 'TRIAL_SUPPORT_ASSEMBLE' not in text:
        text, n['asm'] = re.subn(r'\n(\s*)(for o in \*\.o; do \\\n)',
                                 r'\n\1$(TRIAL_SUPPORT_ASSEMBLE); \\\n\1\2', text)
        text, k = re.subn(r'\n\t@(for o in \*\.o; do \\\n)',
                          r'\n\t@$(TRIAL_SUPPORT_ASSEMBLE); \\\n\t\1', text)
        n['asm'] += k
        if n['asm'] == 0:
            # link loops of another shape: assemble once per recipe shell, before the first link
            text, n['asm_guarded'] = re.subn(
                r'(\n([ \t]*)(?:runtime_obj|rt_one)=""; \\\n)',
                r'\n\2[ -n "$$tsa_done" ] || { $(TRIAL_SUPPORT_ASSEMBLE); tsa_done=1; }; \\\1', text)
    if 'TRIAL_SUPPORT_IN_TMP' not in text:
        text, n['tmp'] = re.subn(
            r'(\n(\s*)echo "\$\$base\.silica" > "\$\$tmpdir/silica\.config"; \\\n)',
            r'\1\2$(call TRIAL_SUPPORT_IN_TMP,$$tmpdir,$$base.silica); \\\n', text)
    return text, n


def main():
    for path in sys.argv[1:]:
        old = open(path).read()
        new, n = patch(old)
        if new != old:
            open(path, 'w').write(new)
        print(path, {k: v for k, v in n.items() if v})


if __name__ == '__main__':
    main()
