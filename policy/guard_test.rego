package lena.guard_test

import data.lena.guard

test_code_change_allowed if {
	count(guard.deny) == 0 with input as {
		"files": [{"path": "plan-tools/src/plan_tools/route.py"}, {"path": "backlog/todo/20261010-x.md"}],
		"added": [{"path": "plan-tools/src/plan_tools/route.py", "line": "return total_px"}],
		"removed": [],
	}
}

test_protected_file_denied if {
	count(guard.deny) == 1 with input as {"files": [{"path": "program.md"}], "added": [], "removed": []}
}

test_protected_dir_denied if {
	count(guard.deny) == 1 with input as {"files": [{"path": "scripts/lena-loop.sh"}], "added": [], "removed": []}
}

test_prefix_lookalike_allowed if {
	count(guard.deny) == 0 with input as {"files": [{"path": "program.md.bak"}, {"path": "configuration.md"}], "added": [], "removed": []}
}

test_confirm_marker_removal_denied if {
	count(guard.deny) == 1 with input as {
		"files": [{"path": "docs/x.md"}],
		"added": [],
		"removed": [{"path": "docs/x.md", "line": "Taux : [À CONFIRMER — Jo]"}],
	}
}

test_price_added_denied if {
	count(guard.deny) == 1 with input as {
		"files": [{"path": "plan-tools/src/plan_tools/bom.py"}],
		"added": [{"path": "plan-tools/src/plan_tools/bom.py", "line": "PRIX = '1 234,50 $'"}],
		"removed": [],
	}
}

test_price_in_tests_allowed if {
	count(guard.deny) == 0 with input as {
		"files": [{"path": "plan-tools/tests/test_bom.py"}],
		"added": [{"path": "plan-tools/tests/test_bom.py", "line": "assert fmt(12.5) == '12,50 $'"}],
		"removed": [],
	}
}
