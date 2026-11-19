#!/bin/bash
# Wait until the Compiler workflow has built this commit, then print its run id.
# Trials compile with that run's artifacts, not with the compilers committed in binaries/.

set -euo pipefail

repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
out="${GITHUB_OUTPUT:?}"

pick() {
    gh api "/repos/${repo}/actions/workflows/compiler.yml/runs?head_sha=${sha}&per_page=20" \
        --jq '[.workflow_runs[] | {id, status, conclusion, html_url, run_number}] | sort_by(.run_number) | reverse | .[0] // empty'
}

echo "looking for a Compiler run of ${sha}"
deadline=$((SECONDS + 30 * 60))
row=""
while :; do
    row=$(pick)
    if [ -n "$row" ]; then
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "no Compiler workflow run for ${sha}" >&2
        echo "Push this branch with a pull request open, or run the Compiler workflow on this commit, then dispatch Trials again." >&2
        exit 1
    fi
    echo "no Compiler run yet; waiting"
    sleep 20
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
