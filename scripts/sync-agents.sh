#!/usr/bin/env bash
# Regenerates the ChatGPT / Codex copies from the Claude sources (RUNBOOK section 12):
#   AGENTS.md  : the block between <!-- LENA:START --> and <!-- LENA:END --> becomes docs/LENA.md verbatim
#   .agents/skills : exact mirror of .claude/skills
# Idempotent. Run from anywhere; exits non-zero if the markers are missing.
# Works on a Windows checkout too (core.autocrlf=true gives CRLF files): the markers are matched with an
# optional trailing CR, and git normalizes the line endings again on "git add".
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

cr=$'\r'
start="^<!-- LENA:START -->${cr}\{0,1\}\$"
end="^<!-- LENA:END -->${cr}\{0,1\}\$"

grep -q "$start" AGENTS.md && grep -q "$end" AGENTS.md || {
    echo "AGENTS.md: markers <!-- LENA:START --> / <!-- LENA:END --> not found" >&2
    exit 1
}

tmp="$(mktemp)"
{
    sed -n "1,/$start/p" AGENTS.md
    cat docs/LENA.md
    sed -n "/$end/,\$p" AGENTS.md
} > "$tmp"
if cmp -s "$tmp" AGENTS.md; then
    echo "AGENTS.md: already in sync"
else
    cat "$tmp" > AGENTS.md
    echo "AGENTS.md: LENA block rewritten from docs/LENA.md"
fi
rm -f "$tmp"

rm -rf .agents/skills
mkdir -p .agents
cp -R .claude/skills .agents/skills
echo ".agents/skills: mirrored from .claude/skills"

# Same check as .github/workflows/ci.yml
sed -n "/$start/,/$end/p" AGENTS.md | sed '1d;$d' | diff -u docs/LENA.md - >/dev/null
diff -ru .claude/skills .agents/skills >/dev/null
echo "parity OK"
