#!/bin/bash
# Does the latest compiler release have a cross compiler for <emit target> that runs on this runner?
#
#   released_compiler_exists.sh <emit target>      e.g. STM32-L476RG_raw
#
# Looks at the release silica-cli installs from (the latest release of $SILICA_REPO, default
# Silica-Language-and-Compiler/silica, as silica-cli's own default) for an asset named
# silica-NNNNNN-<token>-<platform>, the way compiler.yml names a cross compiler (<token> is the emit
# target with hyphens written as underscores; <platform> is this machine's).
#
# Writes available=true or available=false to $GITHUB_OUTPUT (and prints it). A release that cannot be
# read is an error (exit 1), not a missing compiler: only a release that answers and has no such asset
# makes the Trials workflow skip the target's shard.

set -euo pipefail

target="${1:?emit target}"
repo="${SILICA_REPO:-Silica-Language-and-Compiler/silica}"
token="${target//-/_}"
platform="$(make -s --no-print-directory -f project_makefiles/platform/platforms.mk host-platform)"
pattern="^silica-[0-9]{6}-${token}-${platform}\$"

if ! assets="$(gh api "repos/${repo}/releases/latest" --jq '.tag_name + "\n" + ([.assets[].name] | join("\n"))')"; then
    echo "could not read the latest release of ${repo}" >&2
    exit 1
fi
tag="$(printf '%s\n' "$assets" | head -n 1)"
found="$(printf '%s\n' "$assets" | tail -n +2 | grep -E "$pattern" | sort | head -n 1 || true)"

if [ -n "$found" ]; then
    available=true
    echo "release ${tag} of ${repo} has ${found}"
else
    available=false
    echo "::notice::No released ${target} compiler for ${platform} in ${repo} release ${tag}; this shard is skipped."
    {
        echo "### Skipped"
        echo "The latest release of \`${repo}\` (\`${tag}\`) has no \`${target}\` compiler for \`${platform}\`,"
        echo "so this shard installs nothing and runs no trials. It runs once a release carries one."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
echo "available=${available}"
echo "available=${available}" >> "${GITHUB_OUTPUT:-/dev/null}"
