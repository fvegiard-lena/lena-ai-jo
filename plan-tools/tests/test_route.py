from collections import Counter
from dataclasses import replace

import pytest

from plan_tools.catalog import load_catalog
from plan_tools.qpl_io import load
from plan_tools.route import (
    NO_PANEL,
    _Occupancy,
    conduit_segments,
    l_path,
    match_plans,
    route_doc,
)


def _plan(routes, prefix):
    return next(r for r in routes if r.name.startswith(prefix))


def test_routing_is_deterministic(rdoc, route_path, cfg):
    first = route_doc(rdoc, cfg)
    assert route_doc(rdoc, cfg) == first
    assert route_doc(load(route_path), cfg) == first


def test_every_device_reached_exactly_once(rdoc, cfg):
    routes = route_doc(rdoc, cfg)
    a = _plan(routes, "Plan A")
    reached = Counter((d.name, d.x, d.y) for run in a.runs for d in run.devices)
    expected = Counter(
        [("PRISE", 200 + 100 * i, 200) for i in range(14)]
        + [("FIXT TYPE L1", 3000, 400), ("FIXT TYPE L1", 3200, 400), ("FIXT TYPE L1", 3400, 450)]
    )
    assert reached == expected  # ni symbole ignoré (ENL) ni masqué, chacun une seule fois
    for r in routes:
        for run in r.runs:
            assert 1 <= len(run.devices) <= cfg.max_devices_per_run
            assert len(set(run.devices)) == len(run.devices)


def test_segments_axis_aligned_and_contiguous(rdoc, cfg):
    for r in route_doc(rdoc, cfg):
        for run in r.runs:
            cur = run.start
            for x1, y1, x2, y2 in run.segments:
                assert (x1 == x2) != (y1 == y2)  # un seul axe, longueur non nulle
                assert (x1, y1) == cur
                cur = (x2, y2)
            assert cur == run.devices[-1].center
            assert run.length_px == sum(abs(s[2] - s[0]) + abs(s[3] - s[1]) for s in run.segments)


def test_runs_start_at_panel(rdoc, cfg):
    a = _plan(route_doc(rdoc, cfg), "Plan A")
    assert a.panels == ((100, 100),)
    assert [run.tag for run in a.runs] == ["L1", "groupe 1", "groupe 2"]
    assert [len(run.devices) for run in a.runs] == [3, 12, 2]
    assert all(run.from_panel and run.start == (100, 100) for run in a.runs)
    assert a.n_ignored == 2
    assert any("masqué" in f for f in a.flags)
    assert not any(f.startswith(NO_PANEL) for f in a.flags)


def test_no_panel_plan_is_flagged(rdoc, cfg):
    b = _plan(route_doc(rdoc, cfg), "Plan B")
    assert b.flags[0].startswith(NO_PANEL)
    (run,) = b.runs
    assert not run.from_panel and run.start == (900, 500)  # appareil le plus central
    # 2e saut « vertical d'abord » : l'horizontale recouvrirait le 1er segment IA
    assert run.segments == ((900, 500, 500, 500), (500, 500, 500, 900), (500, 900, 900, 900))
    assert run.length_px == 1200


def test_plan_without_devices_has_no_runs(rdoc, cfg):
    c = _plan(route_doc(rdoc, cfg), "Plan C")
    assert c.runs == () and c.flags == ()


def test_l_path_prefers_less_overlap():
    assert l_path((0, 0), (100, 50)) == [(0, 0, 100, 0), (100, 0, 100, 50)]
    occ = _Occupancy(4)
    occ.add((0, 2, 100, 2))  # conduit existant le long de l'horizontale
    assert occ.overlap((0, 0, 100, 0)) == 100
    assert l_path((0, 0), (100, 50), occ) == [(0, 0, 0, 50), (0, 50, 100, 50)]
    assert l_path((0, 0), (0, 80), occ) == [(0, 0, 0, 80)]
    assert l_path((5, 5), (5, 5), occ) == []
    occ.add((10, 10, 300, 900))  # oblique : ignoré
    assert occ.overlap((10, 10, 10, 900)) == 0


def test_existing_conduits_only(rdoc, cfg):
    plan_a = rdoc.root.find("Plans/Plan")
    segs = conduit_segments(plan_a, load_catalog(rdoc.root), cfg)
    assert segs == [(100, 100, 100, 300), (100, 300, 900, 300)]  # « Distance 1 » exclue


def test_tagged_group_split_beyond_max(rdoc, cfg):
    small = replace(cfg, max_devices_per_run=2)
    a = _plan(route_doc(rdoc, small), "Plan A")
    assert [run.tag for run in a.runs][:2] == ["L1.1", "L1.2"]
    assert any("étiquette L1" in f and "scindée" in f for f in a.flags)
    assert sum(len(run.devices) for run in a.runs) == 17


def test_match_plans():
    names = ["X - R1 - 1 1", "X - R1 - 10", "X - R1 - 11", "Delson R4 - 2"]
    assert match_plans(names, "R1 - 1") == [0]
    assert match_plans(names, "r1 - 10") == [1]
    assert match_plans(names, "Dels") == [3]  # repli : sous-chaîne
    assert match_plans(names, None) == [0, 1, 2, 3]
    assert match_plans(names, "R9") == []


def test_plan_filter(rdoc, cfg):
    routes = route_doc(rdoc, cfg, plan_filter="plan b")
    assert [(r.name, r.index) for r in routes] == [("Plan B - L'étage", 1)]


def test_wall_aware_is_not_faked(rdoc, cfg):
    with pytest.raises(NotImplementedError, match="wall-aware"):
        route_doc(rdoc, cfg, wall_aware=True)
