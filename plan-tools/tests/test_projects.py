import os
import time
from pathlib import Path

import pytest

from plan_tools.projects import ProjectError, find_project, projects_root, resolve_target


def _qpl(path: Path, age_s: float) -> Path:
    path.parent.mkdir(exist_ok=True)
    path.write_bytes(b"<QuoterPlanSession/>")
    t = time.time() - age_s
    os.utime(path, (t, t))
    return path


@pytest.fixture
def root(tmp_path):
    a = tmp_path / "S-1849 (3-Mars-2025)"
    for i, name in enumerate(("S-1849 v1.qpl", "S-1849 v2.qpl", "S-1849 - IA.qpl")):
        _qpl(a / name, 100 - i * 10)
    (tmp_path / "S-18490 (1-Mai-2025)").mkdir()  # ne doit pas correspondre à S-1849
    (tmp_path / "S-0001 (1-Janvier-2020)").mkdir()
    return tmp_path


def test_find_newest_excluding_ia(root):
    assert find_project("S-1849", root) == (root / "S-1849 (3-Mars-2025)" / "S-1849 v2.qpl", [])
    assert find_project("s-1849", root)[0].name == "S-1849 v2.qpl"


def test_env_root(root, monkeypatch):
    monkeypatch.setenv("PLAN_TOOLS_PROJECTS_ROOT", str(root))
    assert find_project("S-1849")[0].name == "S-1849 v2.qpl"


def test_default_root_under_home(monkeypatch):
    monkeypatch.delenv("PLAN_TOOLS_PROJECTS_ROOT", raising=False)
    root = projects_root()
    assert root.parents[2] == Path.home()
    assert root.parts[-3:] == (
        "OneDrive - GROUPE DR ELECTRIQUE INC",
        "DANIEL-FRANCIS-JO",
        "Mes projets",
    )


@pytest.mark.parametrize("folder", ["S-0120-1 (3-Janvier-2022)", "S-0120_rev", "S-0120.b"])
def test_code_followed_by_separator(tmp_path, folder):
    qpl = _qpl(tmp_path / folder / "plan.qpl", 10)
    _qpl(tmp_path / "S-01204 (26-Août-2024)" / "autre.qpl", 0)  # S-01204 ≠ S-0120
    assert find_project("S-0120", tmp_path) == (qpl, [])


def test_several_folders_take_most_recent_qpl(tmp_path):
    old = _qpl(tmp_path / "S-0447 (1-Mai-2022)" / "a.qpl", 300)
    _qpl(tmp_path / "S-0447 (1-Mai-2022)" / "a old.qpl", 900)
    new = _qpl(tmp_path / "S-0447-D (28-Octobre-2022)" / "d.qpl", 100)
    mid = _qpl(tmp_path / "S-0447_bis" / "b.qpl", 200)
    (tmp_path / "S-0447 vide").mkdir()  # sans .qpl : listé en dernier
    qpl, others = find_project("S-0447", tmp_path)
    assert qpl == new
    assert others == [mid.parent, old.parent, tmp_path / "S-0447 vide"]


def test_errors_in_french(root):
    with pytest.raises(ProjectError, match="Aucun dossier"):
        find_project("S-4242", root)
    with pytest.raises(ProjectError, match="Aucun fichier .qpl"):
        find_project("S-0001", root)
    (root / "S-0001 (2-Janvier-2020)").mkdir()  # deux dossiers, aucun .qpl
    with pytest.raises(ProjectError, match="Aucun fichier .qpl"):
        find_project("S-0001", root)


def test_resolve_target_accepts_paths(root):
    folder = root / "S-1849 (3-Mars-2025)"
    assert resolve_target(str(folder)) == (folder / "S-1849 v2.qpl", [])
    assert resolve_target(str(folder / "S-1849 v1.qpl")) == (folder / "S-1849 v1.qpl", [])
    assert resolve_target("S-1849", root)[0].name == "S-1849 v2.qpl"
