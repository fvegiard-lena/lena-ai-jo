#!/usr/bin/env bash
# Regenerate the ChatGPT / Codex copies from the Claude sources:
#   docs/LENA.md     -> AGENTS.md, between <!-- LENA:START --> and <!-- LENA:END -->
#   .claude/skills/  -> .agents/skills/ (exact mirror)
# Run from anywhere: bash scripts/sync-agents.sh
# Idempotent. Touches no tracked file when the copies are already in sync.
# The check at the end is made on what git will COMMIT from this checkout, which is what the CI compares:
# the files are added to a private copy of the index (the real index is not touched) and read back from it.
# So line endings that git converts at commit (Windows checkout) do not count, and what git would commit
# differently from what is on disk (a file committed with CRLF, a file .gitignore hides) is caught.
# Refuses, with a message and before writing anything, an input that cannot give a valid AGENTS.md.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

die() {
    echo "sync-agents: $*" >&2
    exit 1
}

start='<!-- LENA:START -->'
end='<!-- LENA:END -->'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v git > /dev/null || die "git not found"
# No 2>/dev/null here: if git refuses this checkout, its own message says why.
git rev-parse --is-inside-work-tree > /dev/null || die "git cannot work in this checkout (run 'git status' here to see why)"
idx="$(git rev-parse --git-path "sync-agents-index.$$")"
trap 'rm -rf "$tmp" "$idx" "$idx.lock"' EXIT

# A private copy of the index: "staged add" does what "git add" would do, without touching the real one.
real="$(git rev-parse --git-path index)"
if [ -f "$real" ]; then cp "$real" "$idx"; fi
staged() { GIT_INDEX_FILE="$idx" git -c core.safecrlf=false "$@"; }
bytes() { wc -c < "$1" | tr -d ' '; }

[ -f docs/LENA.md ] || die "docs/LENA.md not found"
[ -f AGENTS.md ] || die "AGENTS.md not found"
[ -d .claude/skills ] || die ".claude/skills not found"

# docs/LENA.md as git would commit it.
staged add -- docs/LENA.md
staged cat-file blob :docs/LENA.md > "$tmp/lena"
[ -s "$tmp/lena" ] || die "docs/LENA.md is empty"
[ "$(tr -d '\0' < "$tmp/lena" | wc -c | tr -d ' ')" = "$(bytes "$tmp/lena")" ] ||
    die "docs/LENA.md contains NUL bytes (saved as UTF-16?): save it as UTF-8, then run again (nothing was changed)"
[ "$(tr -d '\r' < "$tmp/lena" | wc -c | tr -d ' ')" = "$(bytes "$tmp/lena")" ] ||
    die "docs/LENA.md: git would commit carriage returns (CR) from this checkout, and the CI compares bytes. Save the file with LF line endings, then run again (nothing was changed). Check: git ls-files --eol docs/LENA.md"
[ -z "$(tail -c 1 "$tmp/lena")" ] || die "docs/LENA.md must end with a newline: add one, then run again (nothing was changed)"
if grep -aqxF -e "$start" -e "$end" "$tmp/lena"; then
    die "docs/LENA.md must not contain a '$start' or '$end' line (nothing was changed)"
fi

# AGENTS.md is generated: its own lines (around the block) are always written with LF.
tr -d '\r' < AGENTS.md > "$tmp/frame"
# Exactly one START line, then exactly one END line.
line_of() { grep -anxF -- "$1" "$tmp/frame" | cut -d: -f1 || true; }
one_number() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
s="$(line_of "$start")"
e="$(line_of "$end")"
if ! one_number "$s" || ! one_number "$e" || [ "$s" -ge "$e" ]; then
    die "AGENTS.md: expected exactly one '$start' line, then exactly one '$end' line (nothing was changed). To start again from the last commit: git checkout HEAD -- AGENTS.md"
fi
{
    head -n "$s" "$tmp/frame"
    cat "$tmp/lena"
    tail -n "+$e" "$tmp/frame"
} > "$tmp/new"

# Write AGENTS.md only when what git would commit for it differs from the file just built.
staged add -- AGENTS.md
if staged cat-file blob :AGENTS.md | cmp -s - "$tmp/new"; then
    echo "AGENTS.md: already in sync"
else
    cat "$tmp/new" > AGENTS.md
    echo "AGENTS.md: LENA block rewritten from docs/LENA.md"
fi

# Mirror the skills. The new copy is complete before the old one is moved away.
if [ ! -L .agents ] && [ ! -L .agents/skills ] && [ -d .agents/skills ] && diff -r .claude/skills .agents/skills > /dev/null 2>&1; then
    echo ".agents/skills: already in sync"
else
    if [ -L .agents ]; then rm .agents; fi
    mkdir -p .agents
    rm -rf .agents/skills.new .agents/skills.old
    cp -R .claude/skills .agents/skills.new || { rm -rf .agents/skills.new; die "cannot copy .claude/skills (.agents/skills was left as it was)"; }
    if [ -e .agents/skills ] || [ -L .agents/skills ]; then
        mv .agents/skills .agents/skills.old || { rm -rf .agents/skills.new; die "cannot replace .agents/skills (a file open in another program?); it was left as it was"; }
    fi
    mv .agents/skills.new .agents/skills
    rm -rf .agents/skills.old || echo "sync-agents: could not remove .agents/skills.old: delete it by hand" >&2
    echo ".agents/skills: mirrored from .claude/skills"
fi

# Same check as .github/workflows/ci.yml, on what git will commit.
staged add -- AGENTS.md
staged cat-file blob :AGENTS.md | cmp -s - "$tmp/new" ||
    die "AGENTS.md, as git would commit it, still differs from docs/LENA.md. Check: git ls-files --eol AGENTS.md docs/LENA.md"
staged add -A -- .claude/skills .agents/skills
tab="$(printf '\t')"
# Mode, content and path of every file git would commit under $1, paths relative to $1.
as_committed() { staged -c core.quotepath=false ls-files -s -- "$1" | sed "s|$tab$1/|$tab|"; }
source_side="$(as_committed .claude/skills)"
[ -n "$source_side" ] || die ".claude/skills: git would commit no file from it"
if [ "$source_side" != "$(as_committed .agents/skills)" ]; then
    die ".agents/skills, as git would commit it, still differs from .claude/skills. Usual causes: a file committed with Windows line endings (see: git ls-files --eol .claude/skills .agents/skills ; repair: git add --renormalize .claude/skills .agents/skills) or a file that .gitignore hides (see: git status --ignored .claude/skills .agents/skills ; repair: git add -f <file>)"
fi
echo "parity OK"
