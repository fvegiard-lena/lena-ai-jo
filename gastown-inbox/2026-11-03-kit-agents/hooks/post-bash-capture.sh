#!/usr/bin/env bash
set -euo pipefail

CMD=$(jq -r '.tool_input.command // ""')
OUT=$(jq -r '.tool_response.output // ""' | head -c 4000)

mkdir -p tasks/.logs
{
  echo "=== $(date -u +%FT%TZ) ==="
  echo "\$ $CMD"
  echo "$OUT"
  echo
} >> tasks/.logs/tool-usage.log
exit 0