#!/usr/bin/env bash
# Verifier of the autonomous loop: exit 0 only if the work since <base> may be kept.
#   OPA guard, ruff + pytest (plan-tools, code-rag unit tests), AGENTS.md / skills parity,
#   and the task's own "Check:" line (must start with "uv run ", no shell metacharacters).
# Usage: scripts/lena-check.sh <base-commit> [backlog/todo/<task>.md]
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

base="${1:?usage: lena-check.sh <base-commit> [task-file]}"
task="${2:-}"
fail=0

step() {
    echo "== $*"
    if "$@"; then :; else echo "FAILED: $*"; fail=1; fi
}

# shellcheck disable=SC2329  # called through step
parity() {
    sed -n '/^<!-- LENA:START -->$/,/^<!-- LENA:END -->$/p' AGENTS.md | sed '1d;$d' | diff -u docs/LENA.md - &&
        diff -ru .claude/skills .agents/skills
}

step bash scripts/lena-guard.sh "$base"
step uv run --project plan-tools ruff check plan-tools
step uv run --project plan-tools pytest -q plan-tools
step uv run --project code-rag ruff check code-rag
step uv run --project code-rag pytest -q -m "not integration" code-rag
step parity

if [[ -n "$task" && -f "$task" ]]; then
    check="$(sed -n 's/^Check: *//p' "$task" | head -n 1 | tr -d '\r')"
    if [[ -n "$check" ]]; then
        if [[ "$check" != "uv run "* || "$check" =~ [\;\|\&\$\`\<\>\"\'] ]]; then
            echo "FAILED: unsafe Check line in $task: $check"
            fail=1
        else
            read -ra argv <<< "$check"
            step "${argv[@]}"
        fi
    fi
fi

exit "$fail"
