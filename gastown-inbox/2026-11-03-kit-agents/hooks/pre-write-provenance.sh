#!/usr/bin/env bash
set -euo pipefail

FILE=$(jq -r '.tool_input.file_path // ""')
CONTENT=$(jq -r '.tool_input.content // .tool_input.new_string // ""')

# Trivial edits (comments, whitespace, <5 lines) exempt
LINES=$(printf '%s' "$CONTENT" | wc -l)
[ "$LINES" -lt 5 ] && exit 0

# Check provenance registry exists for this file
REG="tasks/todo.md"
[ -f "$REG" ] || { echo "BLOCKED (§2.3): tasks/todo.md missing" >&2; exit 2; }

# Basic filename match in provenance block
BASENAME=$(basename "$FILE")
if ! grep -q "$BASENAME" "$REG" 2>/dev/null; then
  echo "BLOCKED (§2.3): no provenance entry for $BASENAME in tasks/todo.md." >&2
  echo "Add a row: <file>:<line> — <symbol> / source: <URL> (fetched <date>) / example: <...> / verified: <cmd → ok>" >&2
  exit 2
fi

exit 0