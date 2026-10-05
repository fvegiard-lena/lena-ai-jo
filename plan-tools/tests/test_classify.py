import pytest

from plan_tools.classify import (
    circuit_tag,
    classify,
    classify_report,
    load_config,
    proximity_clusters,
)

SPEC_PANEL = (
    r"(?i)\bpann(eau)?\b(?!.*(annonciateur|tcai|incendie|alarme))|\bPNL\b|\bLP-?\d|\bDP-?\d"
    r"|distribution|\bCDP\b|\bMCC\b|main disj"
)
TOML = (
    "[classify]\npanel = 'PNL'\nignore = 'X'\ndevice = '.'\n"
    "[circuit]\ntag = 'C\\d'\nmax_devices_per_run = {max_n}\n"
    "[route]\nconduit_line = 'c'\nconduit_group = 'c'\noverlap_tolerance_px = 0\n"
)


def test_repo_config_matches_spec(cfg):
    assert cfg.panel.pattern == SPEC_PANEL
    assert cfg.panel_exclude.search("FIXT TYPE LP1") and cfg.panel_exclude.search("DP")
    assert cfg.tag.pattern == r"\b[A-Z]{1,3}-?\d{1,3}\b"
    assert cfg.max_devices_per_run == 12
    assert cfg.conduit_group.search("conduit 3/4 03c12")


@pytest.mark.parametrize(
    ("name", "role"),
    [
        ("PANNEAU A", "panel"),
        ("Panneau", "panel"),
        ("PANNEAU REMPLACER", "panel"),
        ("PANN 100A 120/240V 40CCTC/A MAIN DISJ", "panel"),
        ("PANN 42CCT 120/208V", "panel"),
        ("DP1 (Npp16)", "panel"),
        ("LP-2", "panel"),
        # faux panneaux relevés sur les fichiers réels
        ("DP", "device"),
        ("FIXT LP", "device"),
        ("FIXT TYPE LP1", "device"),
        ("TYPE LP1A", "device"),
        ("DETECTEUR DP1", "device"),
        ("PANNEAU TCAI", "device"),
        ("PANNEAU ANNONCIATEUR PRINCIPAL", "device"),
        ("PANN FEU", "device"),
        ("PANN BEL", "device"),
        ("PANN CONTROL POMPE", "device"),
        ("PANN 30CCT ENL", "ignore"),  # ignore est évalué avant panel
        ("PRISE", "device"),
        ("GFI", "device"),
        ("Compteur 1", "device"),
        ("FIXT TYPE L1", "device"),
        ("PRISE ENL", "ignore"),
        ("Fixt à enlever", "ignore"),
        ("EXISTANT DETECTEUR", "ignore"),
        ("", "ignore"),
        ("   ", "ignore"),
    ],
)
def test_roles(cfg, name, role):
    assert classify(name, cfg) == role


def test_circuit_tag(cfg):
    assert circuit_tag("FIXT TYPE L1", "1", cfg) == "L1"
    assert circuit_tag("CO-4", None, cfg) == "CO-4"
    assert circuit_tag("PRISE", "1", cfg) is None  # @Text numérique : pas une étiquette
    assert circuit_tag("PRISE", "C-12", cfg) == "C-12"  # repli sur @Text
    assert circuit_tag("1000W 347V", None, cfg) is None


def test_proximity_clusters_cover_each_point_once():
    pts = [((i * 37) % 500, (i * 91) % 300) for i in range(30)]
    clusters = proximity_clusters(pts, 12)
    assert [len(c) for c in clusters] == [12, 12, 6]
    assert sorted(i for c in clusters for i in c) == list(range(30))
    assert proximity_clusters(pts, 12) == clusters  # déterministe
    assert proximity_clusters([], 12) == []


def test_proximity_clusters_are_compact():
    left = [(x, 0) for x in range(0, 50, 10)]
    right = [(x, 0) for x in range(1000, 1050, 10)]
    clusters = proximity_clusters(right + left, 5)
    assert [sorted(c) for c in clusters] == [[5, 6, 7, 8, 9], [0, 1, 2, 3, 4]]


def test_env_config_override(tmp_path, monkeypatch):
    (tmp_path / "c.toml").write_text(TOML.format(max_n=3), encoding="utf-8")
    monkeypatch.setenv("PLAN_TOOLS_CONFIG", str(tmp_path / "c.toml"))
    custom = load_config()
    assert custom.max_devices_per_run == 3
    assert classify("PANNEAU", custom) == "device"


def test_invalid_max_rejected(tmp_path):
    (tmp_path / "c.toml").write_text(TOML.format(max_n=0), encoding="utf-8")
    with pytest.raises(ValueError, match="max_devices_per_run"):
        load_config(tmp_path / "c.toml")


def test_classify_report(rdoc, cfg):
    rows = classify_report(rdoc.root, cfg)
    assert [(r.role, r.name, r.symbols) for r in rows] == [
        ("panel", "PANNEAU A", 1),
        ("device", "PRISE", 14),
        ("device", "FIXT TYPE L1", 3),
        ("device", "GFI", 3),
        ("device", "PRISE CACHEE", 1),
        ("ignore", "PRISE ENL", 2),
    ]
    assert rows[2].tag == "L1"
