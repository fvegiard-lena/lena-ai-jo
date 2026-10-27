#!/usr/bin/env bash
# Regenerates the ChatGPT / Codex copies from the Claude sources (RUNBOOK section 12):
#   AGENTS.md  : the block between <!-- LENA:START --> and <!-- LENA:END --> becomes docs/LENA.md verbatim
#   .agents/skills : exact mirror of .claude/skills
# Idempotent. Run from anywhere; exits non-zero if the markers are missing.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

grep -qx '<!-- LENA:START -->' AGENTS.md && grep -qx '<!-- LENA:END -->' AGENTS.md || {
    echo "AGENTS.md: markers <!-- LENA:START --> / <!-- LENA:END --> not found" >&2
    exit 1
}

tmp="$(mktemp)"
{
    sed -n '1,/^<!-- LENA:START -->$/p' AGENTS.md
    cat docs/LENA.md
    sed -n '/^<!-- LENA:END -->$/,$p' AGENTS.md
} > "$tmp"
if cmp -s "$tmp" AGENTS.md; then
    echo "AGENTS.md: already in sync"
else
    mv "$tmp" AGENTS.md
    echo "AGENTS.md: LENA block rewritten from docs/LENA.md"
fi
rm -f "$tmp"

rm -rf .agents/skills
mkdir -p .agents
cp -R .claude/skills .agents/skills
echo ".agents/skills: mirrored from .claude/skills"

# Same check as .github/workflows/ci.yml
sed -n '/^<!-- LENA:START -->$/,/^<!-- LENA:END -->$/p' AGENTS.md | sed '1d;$d' | diff -u docs/LENA.md - >/dev/null
diff -ru .claude/skills .agents/skills >/dev/null
echo "parity OK"
