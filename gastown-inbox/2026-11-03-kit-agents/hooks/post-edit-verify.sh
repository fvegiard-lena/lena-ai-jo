#!/usr/bin/env bash
set -euo pipefail

FILE=$(jq -r '.tool_input.file_path // ""')
EXT="${FILE##*.}"

# Language-specific immediate check (scoped, fast)
case "$EXT" in
  py)
    ruff check "$FILE" 2>&1 || { echo "FAIL: ruff on $FILE — fix before continuing (§3.1)" >&2; exit 2; }
    mypy "$FILE" 2>&1 --no-error-summary || { echo "FAIL: mypy on $FILE — fix before continuing (§3.1)" >&2; exit 2; }
    ;;
  ts|tsx)
    npx tsc --noEmit "$FILE" 2>&1 || { echo "FAIL: tsc on $FILE — fix before continuing (§3.1)" >&2; exit 2; }
    npx eslint "$FILE" 2>&1 || { echo "FAIL: eslint on $FILE — fix before continuing (§3.1)" >&2; exit 2; }
    ;;
  go)
    gofmt -l "$FILE" | grep . && { echo "FAIL: gofmt needed on $FILE (§3.1)" >&2; exit 2; }
    go vet "./..." 2>&1 || { echo "FAIL: go vet — fix before continuing (§3.1)" >&2; exit 2; }
    ;;
  rs)
    cargo clippy --quiet 2>&1 || { echo "FAIL: clippy — fix before continuing (§3.1)" >&2; exit 2; }
    ;;
esac

# Append to verification log (used by stop-gate)
mkdir -p tasks/.logs
echo "$(date -u +%FT%TZ) edited $FILE" >> tasks/.logs/verify.log
exit 0