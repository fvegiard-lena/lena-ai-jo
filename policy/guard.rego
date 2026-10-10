# Guard for the autonomous loop (scripts/lena-loop.sh, docs/BOUCLE.md).
# Input: the diff of one loop iteration, built by policy/diff_to_input.py:
#   {"files": [{"path": "..."}], "added": [{"path": "...", "line": "..."}], "removed": [...]}
# Any message in `deny` makes scripts/lena-guard.sh fail, so the loop reverts the work.
package lena.guard

# Human-owned files and the loop's own machinery. backlog/todo/ stays writable (new tasks).
protected := [
	"program.md",
	"docs/LENA.md",
	"AGENTS.md",
	"CLAUDE.md",
	".claude/",
	".agents/",
	"policy/",
	"scripts/",
	".github/",
	"config/",
	".gitleaks.toml",
	"backlog/done/",
	"backlog/failed/",
]

deny contains msg if {
	some f in input.files
	some p in protected
	is_protected(f.path, p)
	msg := sprintf("protected path changed: %s", [f.path])
}

# LENA.md absolute rule: missing data stays flagged, never silently filled.
deny contains msg if {
	some r in input.removed
	contains(r.line, "CONFIRMER")
	msg := sprintf("[À CONFIRMER] marker removed in %s", [r.path])
}

# LENA.md absolute rule: prices come from Jo only. Tests may hold fixture amounts.
deny contains msg if {
	some a in input.added
	not is_test(a.path)
	regex.match(`\d[\d ,]*[.,]\d{2} ?\$|\$ ?\d`, a.line)
	msg := sprintf("dollar amount added in %s: %s", [a.path, a.line])
}

is_protected(path, p) if path == p

is_protected(path, p) if {
	endswith(p, "/")
	startswith(path, p)
}

is_test(path) if contains(path, "/tests/")
