from PIL import Image

from plan_tools.overlay import (
    MAX_WIDTH,
    overlay_path,
    plan_image,
    render_overlay,
    write_report,
)
from plan_tools.route import route_doc


def _png(path, size):
    # fond blanc en mode palette « P », comme les plans réels
    Image.new("RGB", size, (255, 255, 255)).convert("P").save(path)
    return path


def test_overlay_is_capped_at_4000_px(rdoc, cfg, tmp_path):
    plan_a = route_doc(rdoc, cfg)[0]
    png = _png(tmp_path / "Plan A.png", (6000, 1500))
    dest = render_overlay(png, plan_a, tmp_path / "out" / "a - IA.png")
    with Image.open(dest) as im:
        assert im.size == (MAX_WIDTH, 1000)
        s = MAX_WIDTH / 6000
        x1, y1, x2, y2 = plan_a.runs[0].segments[0]
        r, g, b = im.convert("RGB").getpixel((round((x1 + x2) / 2 * s), round((y1 + y2) / 2 * s)))
        assert r > 240 and b > 240 and 80 < g < 140  # magenta alpha 150 sur fond blanc


def test_small_image_not_upscaled(rdoc, cfg, tmp_path):
    plan_b = route_doc(rdoc, cfg)[1]
    png = _png(tmp_path / "b.png", (1200, 1000))
    dest = render_overlay(png, plan_b, tmp_path / "b - IA.png")
    with Image.open(dest) as im:
        assert im.size == (1200, 1000)


def test_plan_image_and_names(rdoc, cfg, route_path, tmp_path):
    plan_a = route_doc(rdoc, cfg)[0]
    assert plan_image(route_path, plan_a) is None  # pas de PNG à côté de la fixture
    assert overlay_path(tmp_path, 'a/b:c*"d"').name == "a_b_c__d_ - IA.png"


def test_report_in_french(rdoc, cfg, route_path, tmp_path):
    routes = route_doc(rdoc, cfg)
    png = tmp_path / "a - IA.png"
    dest = write_report(tmp_path / "rapport.md", route_path, tmp_path / "x.qpl", routes, {0: png})
    text = dest.read_text(encoding="utf-8")
    assert text.startswith("# Tracé IA des conduits — route")
    assert "**non modifiée**" in text
    assert "| Plan A - RDC | 3 | 17 |" in text
    assert "[À CONFIRMER — Jo] aucun panneau détecté" in text
    assert "[À CONFIRMER — Jo] image introuvable (Plan B.png)" in text
    assert "| 2 | groupe 1 | panneau | 12 |" in text
    assert "Plans sans appareil à relier (1) : Plan C - Vide" in text
    assert "unité d'échelle" in text and "échelle non définie" in text
