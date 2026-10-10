#!/usr/bin/env bash
# Autonomous task loop of Lena (Ralph / autoresearch pattern). Doc: docs/BOUCLE.md
#   For each backlog/todo/*.md: fresh agent session -> scripts/lena-check.sh ->
#   green: commit "loop: <id>" + task to backlog/done/ ; red: git reset --hard, retry later,
#   backlog/failed/ after LENA_MAX_ATTEMPTS. One line per pass in results.tsv.
#   Empty backlog: one planning session (LENA_PLAN=1) that may add tasks, else stop.
# Stops on: empty backlog, LENA_BUDGET_USD spent, LENA_MAX_ITER passes, LENA_MAX_FAIL_STREAK
# red passes in a row, or a STOP file at the repo root. Never on main, never pushes.
# The agent never gets git, network or secrets: claude -p --permission-mode dontAsk with an
# allowlist. LENA_AGENT_CMD replaces claude (tests): called as `$LENA_AGENT_CMD <task|plan> <file>`,
# must print claude's JSON (total_cost_usd, num_turns, session_id, result) on stdout.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

: "${LENA_MAX_ITER:=1000}"
: "${LENA_BUDGET_USD:=20}"
: "${LENA_TASK_BUDGET_USD:=2}"
: "${LENA_MAX_TURNS:=40}"
: "${LENA_MAX_ATTEMPTS:=3}"
: "${LENA_MAX_FAIL_STREAK:=5}"
: "${LENA_PLAN:=1}"
: "${LENA_CHECK_CMD:=scripts/lena-check.sh}"
: "${LENA_AGENT_CMD:=}"

results="$repo/results.tsv"
runs="$repo/.lena-loop"
mkdir -p "$runs" backlog/todo backlog/done backlog/failed
[[ -f "$results" ]] || printf 'time\titer\ttask\tattempt\tstatus\tcost_usd\tturns\tseconds\tsession\tnote\n' > "$results"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "STOP: $1"; exit "${2:-1}"; }

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" != "main" ]] || die "refuse to run on main (use francis-dev or a work branch)"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean: commit or stash first"
if [[ -z "$LENA_AGENT_CMD" ]]; then
    command -v claude >/dev/null || die "claude not found on PATH"
fi

json_field() {
    uv run --no-project python -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    d = {}
v = d.get(sys.argv[1], "")
print(str(v).replace("\t", " ").replace("\n", " ")[:300])' "$1"
}

run_agent() {  # <task|plan> <file>  -> claude JSON on stdout
    local mode="$1" file="$2" prompt
    if [[ -n "$LENA_AGENT_CMD" ]]; then
        "$LENA_AGENT_CMD" "$mode" "$file"
        return
    fi
    if [[ "$mode" == plan ]]; then
        prompt="La backlog est vide. Compare les objectifs de program.md au code et cree au plus 10 taches dans backlog/todo/ au format de backlog/README.md. Ne modifie rien d'autre."
    else
        prompt="Fais la tache recue sur l'entree standard ($file), selon program.md."
    fi
    local isolation=--safe-mode
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && isolation=--bare
    claude -p "$isolation" --output-format json --permission-mode dontAsk \
        --max-turns "$LENA_MAX_TURNS" --max-budget-usd "$LENA_TASK_BUDGET_USD" \
        --allowedTools "Read,Edit,Write,Glob,Grep,Bash(uv run *),Bash(uv sync *),Bash(uv add *)" \
        --append-system-prompt "$(cat docs/LENA.md program.md)" \
        "$prompt" < "$file"
}

revert_to() {
    git reset -q --hard "$1"
    git clean -qfd
}

spent=0
fail_streak=0
planned_empty=0
for ((iter = 1; iter <= LENA_MAX_ITER; iter++)); do
    [[ ! -e STOP ]] || die "STOP file present" 0
    awk -v s="$spent" -v b="$LENA_BUDGET_USD" 'BEGIN { exit !(s >= b) }' && die "budget spent: $spent / $LENA_BUDGET_USD USD" 0
    (( fail_streak < LENA_MAX_FAIL_STREAK )) || die "$fail_streak red passes in a row"

    task="$(find backlog/todo -maxdepth 1 -name '*.md' | LC_ALL=C sort | head -n 1)"
    mode=task
    if [[ -z "$task" ]]; then
        (( LENA_PLAN == 1 && planned_empty == 0 )) || die "backlog empty" 0
        mode=plan
        task="$runs/plan-request.md"
        printf '# Planifier\n\nLa backlog est vide : voir program.md.\n' > "$task"
    fi
    id="$(basename "$task" .md)"
    attempt=$(( $(awk -F'\t' -v t="$id" '$3 == t' "$results" | wc -l) + 1 ))
    base="$(git rev-parse HEAD)"
    start=$SECONDS
    out="$runs/$(date '+%Y%m%d-%H%M%S')-$id.json"
    log "iter $iter: $mode $id (attempt $attempt)"

    agent_ok=1
    run_agent "$mode" "$task" > "$out" 2> "$out.err" || agent_ok=0
    cost="$(json_field total_cost_usd < "$out")"
    turns="$(json_field num_turns < "$out")"
    session="$(json_field session_id < "$out")"
    result="$(json_field result < "$out")"
    spent="$(awk -v s="$spent" -v c="${cost:-0}" 'BEGIN { printf "%.4f", s + c }')"

    status=keep
    note=""
    if (( agent_ok == 0 )); then
        status=revert; note="agent exit non-zero"
    elif [[ "$result" == BLOCKED* ]]; then
        status=revert; note="$result"
    elif [[ "$mode" == plan ]]; then
        bash "$LENA_CHECK_CMD" "$base" > "$out.check.log" 2>&1 || { status=revert; note="check red"; }
    else
        bash "$LENA_CHECK_CMD" "$base" "$task" > "$out.check.log" 2>&1 || { status=revert; note="check red"; }
    fi

    if [[ "$status" == keep && "$mode" == task && -z "$(git status --porcelain)" ]]; then
        status=revert; note="no change made"
    fi

    if [[ "$status" == keep ]]; then
        [[ "$mode" == plan ]] || git mv -k "$task" "backlog/done/$id.md"
        git add -A
        if git diff --cached --quiet; then
            note="${note:-no change}"
        else
            git commit -q -m "loop: $id" -m "$result"
        fi
        fail_streak=0
        if [[ "$mode" == plan ]]; then
            [[ -n "$(find backlog/todo -maxdepth 1 -name '*.md')" ]] || planned_empty=1
        fi
    else
        revert_to "$base"
        fail_streak=$(( fail_streak + 1 ))
        [[ "$mode" != plan ]] || planned_empty=1
        if [[ "$mode" == task ]] && (( attempt >= LENA_MAX_ATTEMPTS )); then
            git mv -k "$task" "backlog/failed/$id.md"
            git commit -q -m "loop: give up $id after $attempt attempts"
            note="$note; moved to failed"
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$iter" "$id" "$attempt" \
        "$status" "${cost:-0}" "$turns" "$(( SECONDS - start ))" "$session" "$note" >> "$results"
    log "iter $iter: $status ($note) cost ${cost:-0} USD, total $spent USD"
done
die "LENA_MAX_ITER=$LENA_MAX_ITER reached" 0
