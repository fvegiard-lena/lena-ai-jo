#!/usr/bin/env bash
set -euo pipefail

# 1. Lint/format/type (staged files only)
STAGED=$(git diff --cached --name-only --diff-filter=ACM)
echo "$STAGED" | grep -E '\.py$' >/dev/null && {
  .venv/bin/ruff check $STAGED || exit 1
  .venv/bin/ruff format --check $STAGED || exit 1
  .venv/bin/mypy $STAGED || exit 1
}
echo "$STAGED" | grep -E '\.(ts|tsx)$' >/dev/null && {
  npx tsc --noEmit || exit 1
  npx eslint $STAGED || exit 1
}

# 2. No suppressors in diff (§1.1)
if git diff --cached | grep -qE '^\+.*(# type: ignore|eslint-disable|@ts-ignore|//nolint|# noqa)'; then
  echo "COMMIT BLOCKED (§1.1): suppressor added. Fix root cause." >&2
  exit 1
fi

# 3. No conflict markers (§1.1)
if git diff --cached | grep -qE '^\+(<<<<<<<|=======|>>>>>>>)'; then
  echo "COMMIT BLOCKED (§1.1): conflict markers." >&2
  exit 1
fi

# 4. No TODO/FIXME added without owner (§1.1)
if git diff --cached | grep -qE '^\+.*\b(TODO|FIXME|HACK)\b' ; then
  if ! git diff --cached | grep -qE '^\+.*\b(TODO|FIXME|HACK)\(@[a-zA-Z0-9_-]+\)'; then
    echo "COMMIT BLOCKED (§1.1): TODO/FIXME without owner (@handle)." >&2
    exit 1
  fi
fi

# 5. Provenance in commit body for non-trivial files (§2.3)
NONTRIVIAL=$(echo "$STAGED" | xargs -I{} sh -c '[ $(wc -l < "{}") -gt 20 ] && echo {}' || true)
if [ -n "$NONTRIVIAL" ]; then
  if ! git diff --cached --stat | grep -q .; then :; fi
  if ! grep -q "Source:" .git/COMMIT_EDITMSG 2>/dev/null; then
    echo "COMMIT BLOCKED (§2.3): non-trivial files in commit without 'Source:' line." >&2
    echo "Add to commit body: Source: <URL> (fetched <date>)" >&2
    exit 1
  fi
fi

exit 0