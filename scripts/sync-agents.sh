#!/usr/bin/env bash
# Regenerates the ChatGPT / Codex copies from the Claude sources (RUNBOOK section 12):
#   AGENTS.md  : the block between <!-- LENA:START --> and <!-- LENA:END --> becomes docs/LENA.md verbatim
#   .agents/skills : exact mirror of .claude/skills
# Idempotent: when everything is already in sync, no file is touched. Run from anywhere; exits non-zero if the
# markers are missing.
# Works on a Windows checkout too (core.autocrlf=true gives CRLF files): everything is compared and built on
# copies without carriage returns, because Git Bash's sed and grep do not treat CR the way Linux does.
# A rewritten AGENTS.md is written with LF; git handles the line endings from there.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tr -d '\r' < AGENTS.md > "$tmp/agents"
tr -d '\r' < docs/LENA.md > "$tmp/lena"

grep -qx '<!-- LENA:START -->' "$tmp/agents" && grep -qx '<!-- LENA:END -->' "$tmp/agents" || {
    echo "AGENTS.md: markers <!-- LENA:START --> / <!-- LENA:END --> not found" >&2
    exit 1
}

{
    sed -n '1,/^<!-- LENA:START -->$/p' "$tmp/agents"
    cat "$tmp/lena"
    sed -n '/^<!-- LENA:END -->$/,$p' "$tmp/agents"
} > "$tmp/new"
if cmp -s "$tmp/new" "$tmp/agents"; then
    echo "AGENTS.md: already in sync"
else
    cat "$tmp/new" > AGENTS.md
    echo "AGENTS.md: LENA block rewritten from docs/LENA.md"
fi

if [ -d .agents/skills ] && diff -r .claude/skills .agents/skills >/dev/null 2>&1; then
    echo ".agents/skills: already in sync"
else
    rm -rf .agents/skills
    mkdir -p .agents
    cp -R .claude/skills .agents/skills
    echo ".agents/skills: mirrored from .claude/skills"
fi

# Same check as .github/workflows/ci.yml, on the content as CI sees it (LF)
tr -d '\r' < AGENTS.md | sed -n '/^<!-- LENA:START -->$/,/^<!-- LENA:END -->$/p' | sed '1d;$d' | diff -u "$tmp/lena" - >/dev/null
diff -r .claude/skills .agents/skills >/dev/null
echo "parity OK"
