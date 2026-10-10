"""Turn `git diff <base>` (working tree, untracked files included) into the OPA input of guard.rego.

Usage: python policy/diff_to_input.py <base-commit>   -> JSON on stdout
Untracked files must be visible to git diff first (`git add -A -N`, done by scripts/lena-guard.sh).
"""

import json
import subprocess
import sys


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-c", "core.quotepath=off", *args],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    ).stdout


def main(base: str) -> None:
    files = [{"path": p} for p in git("diff", "--name-only", base).splitlines() if p]
    added, removed = [], []
    old_path = path = None
    in_header = False
    for line in git(
        "diff", "--unified=0", "--no-color", "--no-prefix", base
    ).splitlines():
        if line.startswith("diff --git "):
            in_header, old_path, path = True, None, None
        elif line.startswith("@@"):
            in_header = False
        elif in_header and line.startswith("--- "):
            old_path = None if line == "--- /dev/null" else line[4:]
        elif in_header and line.startswith("+++ "):
            path = old_path if line == "+++ /dev/null" else line[4:]
        elif in_header:
            continue
        elif line.startswith("+") and path:
            added.append({"path": path, "line": line[1:]})
        elif line.startswith("-") and path:
            removed.append({"path": path, "line": line[1:]})
    json.dump(
        {"files": files, "added": added, "removed": removed},
        sys.stdout,
        ensure_ascii=False,
    )


if __name__ == "__main__":
    main(sys.argv[1])
