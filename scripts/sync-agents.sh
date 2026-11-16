#!/usr/bin/env bash
# Regenerate the ChatGPT / Codex copies from the Claude sources:
#   docs/LENA.md     -> AGENTS.md, between <!-- LENA:START --> and <!-- LENA:END -->
#   .claude/skills/  -> .agents/skills/ (exact mirror)
# Run from anywhere: bash scripts/sync-agents.sh
# Idempotent. Touches no file when the copies are already in sync. Works on what git will COMMIT, so the
# result is what the CI checks: on a Windows checkout (files in CRLF, which git turns back into LF at
# commit) the carriage returns are ignored; where git commits bytes as they are, they are compared as is.
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

# The file as git would commit it from this checkout: without CR when git converts line endings
# (core.autocrlf, .gitattributes), unchanged otherwise. Git answers itself; nothing is written to the repo.
as_committed() {
    if [ "$(git hash-object -- "$1")" = "$(tr -d '\r' < "$1" | git hash-object --stdin)" ] && ! cr_in_index "$1"; then
        tr -d '\r' < "$1"
    else
        cat "$1"
    fi
}
# Git's own exception: a file already committed with CR is not converted by core.autocrlf.
cr_in_index() { git ls-files --eol -- "$1" 2> /dev/null | grep -qE '^i/(crlf|mixed)'; }

command -v git > /dev/null || die "git not found"
as_committed docs/LENA.md > "$tmp/lena"
as_committed AGENTS.md > "$tmp/agents"
# AGENTS.md is generated: its own lines (around the block) are always written with LF.
tr -d '\r' < AGENTS.md > "$tmp/frame"

[ -s "$tmp/lena" ] || die "docs/LENA.md is empty"
[ -z "$(tail -c 1 "$tmp/lena")" ] || die "docs/LENA.md must end with a newline: add one, then run again (nothing was changed)"
if grep -qxF -e "$start" -e "$end" "$tmp/lena"; then
    die "docs/LENA.md must not contain a '$start' or '$end' line (nothing was changed)"
fi

# Exactly one START line, then exactly one END line.
line_of() { grep -nxF -- "$1" "$tmp/frame" | cut -d: -f1 || true; }
one_number() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
s="$(line_of "$start")"
e="$(line_of "$end")"
if ! one_number "$s" || ! one_number "$e" || [ "$s" -ge "$e" ]; then
    die "AGENTS.md: expected exactly one '$start' line, then exactly one '$end' line (nothing was changed). To start again from the last commit: git checkout -- AGENTS.md"
fi

{
    head -n "$s" "$tmp/frame"
    cat "$tmp/lena"
    tail -n "+$e" "$tmp/frame"
} > "$tmp/new"

if cmp -s "$tmp/new" "$tmp/agents"; then
    echo "AGENTS.md: already in sync"
else
    cat "$tmp/new" > AGENTS.md
    echo "AGENTS.md: LENA block rewritten from docs/LENA.md"
fi

if [ -d .agents/skills ] && diff -r .claude/skills .agents/skills > /dev/null 2>&1; then
    echo ".agents/skills: already in sync"
else
    rm -rf .agents/skills
    mkdir -p .agents
    cp -R .claude/skills .agents/skills
    echo ".agents/skills: mirrored from .claude/skills"
fi

# Same check as .github/workflows/ci.yml, on what git will commit.
as_committed AGENTS.md > "$tmp/agents"
if ! sed -n "/^$start\$/,/^$end\$/p" "$tmp/agents" | sed '1d;$d' | cmp -s - "$tmp/lena"; then
    die "AGENTS.md still differs from docs/LENA.md as git would commit them (carriage returns that git does not convert here?). Check: git ls-files --eol AGENTS.md docs/LENA.md"
fi
diff -r .claude/skills .agents/skills > /dev/null || die ".agents/skills still differs from .claude/skills"
echo "parity OK"
