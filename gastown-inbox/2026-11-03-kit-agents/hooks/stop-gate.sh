#!/usr/bin/env bash
set -euo pipefail

# Read stop payload
PAYLOAD=$(cat)
STOP_REASON=$(echo "$PAYLOAD" | jq -r '.stop_reason // "end_turn"')

# Allow only explicit end-turn with clean state
[ "$STOP_REASON" != "end_turn" ] && exit 0

FAIL=0

# 1. Clean-room pass must have run and passed (§1.3)
if [ ! -f tasks/.logs/clean-room.log ]; then
  echo "STOP BLOCKED (§1.3): clean-room pass never ran." >&2
  echo "Run: lint → format → type → build → tests, append to tasks/.logs/clean-room.log" >&2
  FAIL=1
elif ! grep -q "ALL GREEN" tasks/.logs/clean-room.log; then
  echo "STOP BLOCKED (§1.3): clean-room pass not green. Last 20 lines:" >&2
  tail -20 tasks/.logs/clean-room.log >&2
  FAIL=1
fi

# 2. Every incomplete item in todo.md must be classified (§1.5)
if [ -f tasks/todo.md ]; then
  if grep -qE '^\s*-\s*\[\s*\]' tasks/todo.md; then
    echo "STOP BLOCKED (§1.5): unchecked items in tasks/todo.md. Classify each as AUTO-FIX / GUARDED-FIX / STOP with proof." >&2
    grep -E '^\s*-\s*\[\s*\]' tasks/todo.md >&2
    FAIL=1
  fi
fi

# 3. Any [unverified] tag must have a §8.6 ledger row (§6.7)
if [ -f tasks/todo.md ] && grep -q '\[unverified\]' tasks/todo.md; then
  if ! grep -q "## Search Space Ledger" tasks/todo.md; then
    echo "STOP BLOCKED (§6.7/§8.6): [unverified] present without Search Space Ledger." >&2
    FAIL=1
  fi
fi

# 4. Recent edits must have verification entries (§3.1)
RECENT_EDITS=$(grep -c "edited " tasks/.logs/verify.log 2>/dev/null || echo 0)
RECENT_VERIFY=$(wc -l < tasks/.logs/verify.log 2>/dev/null || echo 0)
if [ "$RECENT_EDITS" -gt "$RECENT_VERIFY" ]; then
  echo "STOP BLOCKED (§3.1): edits without verification log entries." >&2
  FAIL=1
fi

[ "$FAIL" -eq 1 ] && exit 2
exit 0