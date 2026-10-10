#!/usr/bin/env bash
# OPA guard for one loop iteration: fails if the diff since <base> breaks policy/guard.rego.
# Fails closed: a missing opa, a broken policy or an unreadable diff all count as a denial.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

base="${1:?usage: lena-guard.sh <base-commit>}"
command -v opa >/dev/null || { echo "lena-guard: opa not found (mise use -g opa@latest)" >&2; exit 2; }

git add -A -N  # make untracked files visible to git diff
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
uv run --no-project python policy/diff_to_input.py "$base" > "$input"

# --fail-defined: exit 1 as soon as one deny message exists
if opa eval --fail-defined -f pretty -d policy/guard.rego -i "$input" 'data.lena.guard.deny[msg]'; then
    echo "lena-guard: OK"
else
    echo "lena-guard: DENIED" >&2
    exit 1
fi
