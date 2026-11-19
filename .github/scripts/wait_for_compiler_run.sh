#!/bin/bash
# Wait until the Compiler workflow has built this commit, then print its run id.
# Trials compile with that run's artifacts, not with the compilers committed in binaries/.
#
# The Compiler workflow only runs for changes under compiler/, trials/ or binaries/,
# (ignoring compiler/design_documents/ and compiler/tutorials_and_howtos/),
# so a commit that touches none of them never gets its own run. For such a commit
# this reuses the newest successful Compiler run whose commit is an ancestor of this
# one, provided nothing under those directories changed in between. The check uses
# the API only (the plan job checks out with fetch-depth 1, so there is no local history).
# A reused run's artifacts may have expired (retention period); the install step that
# downloads them would then fail.

set -euo pipefail

repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
out="${GITHUB_OUTPUT:?}"

pick() {
    gh api "/repos/${repo}/actions/workflows/compiler.yml/runs?head_sha=${sha}&per_page=20" \
        --jq '[.workflow_runs[] | {id, status, conclusion, html_url, run_number}] | sort_by(.run_number) | reverse | .[0] // empty'
}

# Print "<run_id> <head_sha> <html_url>" of the newest successful Compiler run that is an
# ancestor of ${sha}, when no file under compiler/, trials/ or binaries/ changed since.
# Prints nothing when a relevant change exists, the diff is too large to tell, or no
# such run is found.
find_reusable_run() {
    local candidates cand_sha cand_id cand_url cmp status count changed
    candidates=$(gh api "/repos/${repo}/actions/workflows/compiler.yml/runs?status=success&per_page=50" \
        --jq '.workflow_runs[] | [.id, .head_sha, .html_url] | @tsv') || return 0
    while IFS=$'\t' read -r cand_id cand_sha cand_url; do
        [ -n "$cand_id" ] || continue
        cmp=$(gh api "repos/${repo}/compare/${cand_sha}...${sha}" 2>/dev/null \
            --jq '{status, count: (.files // [] | length), changed: ([(.files // [])[].filename | select((startswith("compiler/") or startswith("trials/") or startswith("binaries/")) and (startswith("compiler/design_documents/") or startswith("compiler/tutorials_and_howtos/") | not))] | length)}') || continue
        status=$(printf '%s' "$cmp" | jq -r '.status')
        case "$status" in
            ahead | identical) ;;
            *) continue ;;
        esac
        count=$(printf '%s' "$cmp" | jq -r '.count')
        changed=$(printf '%s' "$cmp" | jq -r '.changed')
        # The compare API lists at most 300 files; with that many, assume the worst.
        if [ "$count" -ge 300 ] || [ "$changed" -gt 0 ]; then
            return 0
        fi
        printf '%s %s %s\n' "$cand_id" "$cand_sha" "$cand_url"
        return 0
    done <<< "$candidates"
}

echo "looking for a Compiler run of ${sha}"
row=$(pick)
reused=""
if [ -z "$row" ]; then
    reused=$(find_reusable_run)
    if [ -n "$reused" ]; then
        read -r reuse_id reuse_sha reuse_url <<< "$reused"
        echo "No Compiler run for ${sha}: nothing under compiler/, trials/ or binaries/ changed since ${reuse_sha}."
        echo "Reusing Compiler run ${reuse_id} of ${reuse_sha}: ${reuse_url}"
        echo "run_id=${reuse_id}" >> "$out"
        {
            echo "### Compiler"
            echo "No Compiler run exists for \`${sha}\` because nothing under compiler/, trials/ or binaries/ changed."
            echo "Trials reuse [Compiler run ${reuse_id}](${reuse_url}) of \`${reuse_sha}\`."
        } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
        exit 0
    fi
fi

deadline=$((SECONDS + 30 * 60))
while :; do
    if [ -n "$row" ]; then
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "no Compiler workflow run for ${sha}" >&2
        echo "The Compiler workflow runs only for pushes and pull requests that change compiler/, trials/ or binaries/." >&2
        echo "This commit changed one of them (or no earlier successful Compiler run of an ancestor commit was found)." >&2
        echo "Push this branch with a pull request open, or run the Compiler workflow on this commit, then dispatch Trials again." >&2
        exit 1
    fi
    echo "no Compiler run yet; waiting"
    sleep 20
    row=$(pick)
done

run_id=$(printf '%s' "$row" | jq -r '.id')
status=$(printf '%s' "$row" | jq -r '.status')
url=$(printf '%s' "$row" | jq -r '.html_url')
echo "Compiler run ${run_id} is ${status}: ${url}"

if [ "$status" != "completed" ]; then
    gh run watch "$run_id" --exit-status
fi

conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion')
if [ "$conclusion" != "success" ]; then
    echo "Compiler run ${run_id} finished ${conclusion}: ${url}" >&2
    exit 1
fi

echo "run_id=${run_id}" >> "$out"
{
    echo "### Compiler"
    echo "Trials use [Compiler run ${run_id}](${url}) for \`${sha}\`."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
