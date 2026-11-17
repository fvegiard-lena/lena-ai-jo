#!/usr/bin/env bash
set -euo pipefail

PAYLOAD=$(cat)
OUTPUT=$(echo "$PAYLOAD" | jq -r '.output // ""')

# Subagent output must contain a filled classification table (§1.5)
if ! echo "$OUTPUT" | grep -qE '\|\s*(AUTO-FIX|GUARDED-FIX|STOP)\s*\|'; then
  echo "SUBAGENT BLOCKED (§1.5): no classification table in output. Return before/action/after/verify rows." >&2
  exit 2
fi

# Subagent output must include tool usage report (§5.5)
if ! echo "$OUTPUT" | grep -qE 'Tools used:'; then
  echo "SUBAGENT BLOCKED (§5.5): no tool usage report." >&2
  exit 2
fi

exit 0