#!/usr/bin/env bash
# Self-test of scripts/lena-loop.sh with a stub agent (no claude, no cost), in a throwaway copy
# of the working tree. Real OPA guard; the stub check only adds "BAD.txt must not exist".
# Needs: git, uv, opa. Run: bash scripts/test-lena-loop.sh
# shellcheck disable=SC2016,SC2034  # expectations are single-quoted on purpose: expect() evals them
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
work="$tmp/repo"
mkdir -p "$work"

(cd "$repo" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$work"

cat > "$tmp/agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$(cat "$2")" in
    *"MODE: ok"*) echo "done" > plan-tools/LOOP_OK.txt ;;
    *"MODE: bad"*) echo "broken" > BAD.txt ;;
    *"MODE: protected"*) echo "agent edit" >> program.md ;;
esac
printf '{"total_cost_usd": 0.01, "num_turns": 1, "session_id": "stub", "result": "stub done"}\n'
EOF
cat > "$tmp/check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e BAD.txt ]]
bash scripts/lena-guard.sh "$1"
EOF
chmod +x "$tmp/agent.sh" "$tmp/check.sh"

cd "$work"
git init -q -b work
git config user.name "loop-test"
git config user.email "loop-test@example.invalid"
printf '# ok\n\nMODE: ok\n' > backlog/todo/a-ok.md
printf '# bad\n\nMODE: bad\n' > backlog/todo/b-bad.md
printf '# protected\n\nMODE: protected\n' > backlog/todo/c-protected.md
printf '# noop\n\nMODE: noop\n' > backlog/todo/d-noop.md
git add -A
git commit -q -m "fixture"
program_before="$(git hash-object program.md)"

LENA_AGENT_CMD="$tmp/agent.sh" LENA_CHECK_CMD="$tmp/check.sh" LENA_PLAN=0 \
    LENA_MAX_ATTEMPTS=2 LENA_MAX_FAIL_STREAK=10 bash scripts/lena-loop.sh

fail=0
expect() {
    if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}
expect "ok task kept and moved to done" '[[ -f backlog/done/a-ok.md && -f plan-tools/LOOP_OK.txt ]]'
expect "ok task committed" 'git log --format=%s | grep -qx "loop: a-ok"'
expect "bad task reverted, then failed" '[[ ! -e BAD.txt && -f backlog/failed/b-bad.md ]]'
expect "protected edit reverted, then failed" '[[ "$(git hash-object program.md)" == "$program_before" && -f backlog/failed/c-protected.md ]]'
expect "no-change task never kept, then failed" '[[ -f backlog/failed/d-noop.md && ! -f backlog/done/d-noop.md ]]'
expect "backlog empty" '[[ -z "$(find backlog/todo -name "*.md")" ]]'
expect "7 passes logged" '[[ "$(tail -n +2 results.tsv | wc -l)" -eq 7 ]]'
expect "1 keep logged" '[[ "$(awk -F"\t" "\$5 == \"keep\"" results.tsv | wc -l)" -eq 1 ]]'
expect "tree clean" '[[ -z "$(git status --porcelain)" ]]'

git checkout -q -b main
expect "refuses main" '! bash scripts/lena-loop.sh >/dev/null 2>&1'

exit "$fail"
