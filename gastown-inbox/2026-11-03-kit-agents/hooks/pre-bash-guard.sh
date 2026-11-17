#!/usr/bin/env bash
# Reads hook JSON from stdin: { tool_name, tool_input: { command } }
set -euo pipefail

CMD=$(jq -r '.tool_input.command // ""')

# Banned: suppressors, force-push, destructive
if echo "$CMD" | grep -qE '(rm -rf /|git push --force|--no-verify|--force-with-lease=)'; then
  echo "BLOCKED (§1.1/§9.4): destructive or hook-bypassing command: $CMD" >&2
  exit 2
fi

# Banned: silent install of globally-scoped tooling (§1.4)
if echo "$CMD" | grep -qE '(pip install (?!.*venv)|npm install -g)'; then
  echo "BLOCKED (§1.4): install must be local/venv/npx, not global. Use:" >&2
  echo "  python -m venv .venv && . .venv/bin/activate && pip install ..." >&2
  echo "  npx <pkg> or npm i -D <pkg>" >&2
  exit 2
fi

exit 0