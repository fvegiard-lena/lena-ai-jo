import os
import shutil

from PIL import Image
from typer.testing import CliRunner

from plan_tools.cli import app, out_dir
from plan_tools.qpl_io import roundtrip_check

runner = CliRunner()


def _project(tmp_path, route_path, with_png_b=True):
    proj = tmp_path / "S-9998 (5-Octobre-2026)"
    proj.mkdir()
    qpl = proj / "S-9998 (5-Octobre-2026).qpl"
    shutil.copy(route_path, qpl)
    Image.new("RGB", (5000, 1000), (255, 255, 255)).convert("P").save(proj / "Plan A.png")
    if with_png_b:
        Image.new("RGB", (1500, 1200), (255, 255, 255)).save(proj / "Plan B.png")
    return proj, qpl


def test_route_cli_default_out_and_no_overwrite(route_path, tmp_path, monkeypatch):
    proj, qpl = _project(tmp_path, route_path)
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "local"))
    before = qpl.read_bytes()
    res = runner.invoke(app, ["route", str(qpl)])
    assert res.exit_code == 0, res.output
    lines = res.output.strip().splitlines()
    assert len(lines) == 3
    assert lines[0].startswith("Plans tracés : 2/3 ; parcours : 4 ; appareils reliés : 20")
    assert "[À CONFIRMER — Jo] : 1 plan(s) sans panneau" in lines[1]
    out = tmp_path / "local" / "plan-tools" / "out" / qpl.stem
    ia = out / f"{qpl.stem} - IA.qpl"
    assert roundtrip_check(ia).byte_equal
    report = (out / "rapport.md").read_text("utf-8").splitlines()
    assert report[2:7] == [
        "## Pour Jo",
        "",
        f"1. Original intact (jamais modifié) : `{qpl}`",
        f"2. Résultat à ouvrir dans Plan Expert : `{ia.name}`",
        "3. **[À CONFIRMER — Jo]** (a) détection des panneaux (1 plan(s) sans panneau détecté ; "
        "règles `config.toml`) ; (b) Plan Expert accepte-t-il les Line « IA conduit 3/4 – … » "
        "qui reprennent le GroupID 97 ?",
    ]
    with Image.open(out / "Plan A - RDC - IA.png") as im:
        assert im.width == 4000
    assert (out / "Plan B - L'étage - IA.png").is_file()
    assert qpl.read_bytes() == before  # original intact
    assert sorted(p.name for p in proj.iterdir()) == sorted(
        ["Plan A.png", "Plan B.png", qpl.name]
    )  # rien écrit dans le dossier du projet
    again = runner.invoke(app, ["route", str(qpl)])
    assert again.exit_code == 2 and "--force" in again.output
    forced = runner.invoke(app, ["route", str(qpl), "--force"])
    assert forced.exit_code == 0, forced.output


def test_route_cli_plan_filter_and_missing_image(route_path, tmp_path):
    _, qpl = _project(tmp_path, route_path, with_png_b=False)
    res = runner.invoke(app, ["route", str(qpl), "--plan", "Plan B", "--out", str(tmp_path / "o")])
    assert res.exit_code == 0, res.output
    assert "Plans tracés : 1/1" in res.output
    assert "image introuvable" in res.output
    assert not list((tmp_path / "o").glob("*.png"))
    assert "image introuvable (Plan B.png)" in (tmp_path / "o" / "rapport.md").read_text("utf-8")


def test_route_cli_errors(route_path, tmp_path):
    out = ["--out", str(tmp_path / "o")]
    res = runner.invoke(app, ["route", str(route_path), "--wall-aware", *out])
    assert res.exit_code == 2 and "pas encore implémenté" in res.output
    res = runner.invoke(app, ["route", str(route_path), "--plan", "Plan Z", *out])
    assert res.exit_code == 2 and "Aucun symbole à router sur « Plan Z »" in res.output
    assert "aucun plan ne correspond" in res.output
    res = runner.invoke(app, ["route", str(route_path), "--plan", "Plan C", *out])
    assert res.exit_code == 2 and "Aucun symbole à router sur « Plan C »" in res.output
    assert "« Plan C - Vide » sans appareil à relier" in res.output
    assert not (tmp_path / "o").exists()  # ni rapport.md vide ni - IA.qpl


def test_locked_output_file_is_reported_in_french(mini_path, tmp_path):
    out = tmp_path / "o"
    (out / "mini.bom.csv").mkdir(parents=True)  # chemin de sortie inutilisable (comme verrouillé)
    res = runner.invoke(app, ["bom", str(mini_path), "--out", str(out)])
    assert res.exit_code == 2, res.output
    assert "Impossible d'écrire « " in res.output and "mini.bom.csv" in res.output
    assert "ferme-le (Excel / Plan Expert) puis relance." in res.output
    assert "Traceback" not in res.output
    (out / "mini.inventaire.json").mkdir()
    res = runner.invoke(app, ["inventory", str(mini_path), "--out", str(out)])
    assert res.exit_code == 2 and "mini.inventaire.json" in res.output, res.output


def test_classify_report_cli(route_path):
    res = runner.invoke(app, ["classify-report", str(route_path)])
    assert res.exit_code == 0, res.output
    assert "panel" in res.output and "PANNEAU A" in res.output
    assert "ignore" in res.output and "PRISE ENL" in res.output
    assert "[À CONFIRMER — Jo]" in res.output


def test_inventory_default_out_is_localappdata(mini_path, tmp_path, monkeypatch):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    res = runner.invoke(app, ["inventory", str(mini_path)])
    assert res.exit_code == 0, res.output
    out = tmp_path / "plan-tools" / "out" / "mini"
    assert (out / "mini.inventaire.csv").is_file()
    assert (out / "mini.inventaire.json").is_file()
    assert "Symboles (Counter) : 2" in res.output


def test_bom_with_out(mini_path, tmp_path):
    res = runner.invoke(app, ["bom", str(mini_path), "--out", str(tmp_path / "x")])
    assert res.exit_code == 0, res.output
    assert (tmp_path / "x" / "mini.bom.csv").is_file()
    assert "Lignes BOM : 5" in res.output


def test_out_ia_is_next_to_qpl(mini_path):
    assert out_dir(mini_path, "IA") == mini_path.parent / "IA"
    assert out_dir(mini_path, "ia") == mini_path.parent / "IA"


def test_roundtrip_check_single_and_all(mini_path, tmp_path):
    res = runner.invoke(app, ["roundtrip-check", str(mini_path)])
    assert res.exit_code == 0, res.output
    assert "OK" in res.output and "100.0%" in res.output
    (tmp_path / "p").mkdir()
    shutil.copy(mini_path, tmp_path / "p" / "a.qpl")
    (tmp_path / "p" / "b.qpl").write_bytes(b"<broken")
    res = runner.invoke(app, ["roundtrip-check", "--all", str(tmp_path / "p")])
    assert res.exit_code == 1
    assert "ÉCHEC" in res.output and "50.0%" in res.output


def test_find_project_cli(mini_path, tmp_path, monkeypatch):
    proj = tmp_path / "S-9999 (2-Juillet-2025)"
    proj.mkdir()
    shutil.copy(mini_path, proj / "S-9999 (2-Juillet-2025).qpl")
    monkeypatch.setenv("PLAN_TOOLS_PROJECTS_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "local"))
    res = runner.invoke(app, ["find-project", "S-9999"])
    assert res.exit_code == 0 and "S-9999 (2-Juillet-2025).qpl" in res.output
    res = runner.invoke(app, ["inventory", "S-9999"])
    assert res.exit_code == 0, res.output
    res = runner.invoke(app, ["find-project", "S-4242"])
    assert res.exit_code == 2 and "Aucun dossier" in res.output


def test_find_project_cli_several_folders(mini_path, tmp_path, monkeypatch):
    old = tmp_path / "S-0447 (1-Mai-2022)"
    new = tmp_path / "S-0447-D (28-Octobre-2022)"
    for folder in (old, new):
        folder.mkdir()
        shutil.copy(mini_path, folder / "plan.qpl")
    t = (new / "plan.qpl").stat().st_mtime
    os.utime(old / "plan.qpl", (t - 60, t - 60))
    monkeypatch.setenv("PLAN_TOOLS_PROJECTS_ROOT", str(tmp_path))
    res = runner.invoke(app, ["find-project", "S-0447"])
    assert res.exit_code == 0, res.output
    assert (
        "Plusieurs dossiers trouvés, j'ai pris : S-0447-D (28-Octobre-2022) "
        "(autres : S-0447 (1-Mai-2022))"
    ) in res.output
    assert str(new / "plan.qpl") in res.output
