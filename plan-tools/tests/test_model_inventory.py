import csv
import json

import pytest
from lxml import etree

from plan_tools.catalog import load_catalog
from plan_tools.inventory import FIELDS, build_inventory, write_csv, write_json
from plan_tools.model import item_from_element, plans, polygon_area, polyline_length, to_float


def test_plans_and_scales(mini_doc):
    ps = plans(mini_doc.root)
    assert [p.name for p in ps] == ["Plan A - RDC", "Plan B - L'étage & toit"]
    assert [p.scale_value for p in ps] == [0.0, 0.09375]
    assert [p.filename for p in ps] == ["Plan A - RDC.png", "Plan B.png"]
    assert [(lay.index, lay.name) for lay in ps[0].layers] == [
        (0, "Calque par défaut"),
        (1, "Nouveau calque 1"),
    ]
    assert ps[0].layers[1].items == ()


def test_geometry_helpers():
    assert to_float("0,125") == 0.125
    assert polyline_length([(0, 0), (3, 4)]) == 5
    assert polyline_length([(0, 0), (10, 0), (10, 10), (0, 10)], closed=True) == 40
    assert polygon_area([(0, 0), (10, 0), (10, 10), (0, 10)]) == 100
    assert polyline_length([(0, 0), (3, 4)], closed=True) == 5  # pas de fermeture à 2 points


def test_closed_perimeter_with_two_points_measured_once():
    el = etree.fromstring(
        '<Perimeter Name="P"><Element Closed="True">'
        '<Point X="0" Y="0"/><Point X="30" Y="40"/></Element></Perimeter>'
    )
    item = item_from_element(el)
    assert (item.n_segments, item.length_px) == (1, 50.0)


def test_inventory_counts_and_lengths(mini_doc):
    rows = build_inventory(mini_doc)
    assert [r.kind for r in rows] == [
        "Counter",
        "Line",
        "Area",
        "Rectangle",
        "Legend",
        "Line",
        "Perimeter",
        "Note",
    ]
    counter, line, area = rows[0], rows[1], rows[2]
    assert (counter.name, counter.count, counter.group_id) == ("ET PRISE", 2, 27)
    assert (line.n_segments, line.length_px, line.length_scaled) == (3, 1200.0, None)
    assert line.key == "19PE0.75 #12" and line.description == "conduit 3/4 03c12"
    assert (area.length_px, area.area_px2, area.n_segments) == (400.0, 10000.0, 4)
    line_b, perim = rows[5], rows[6]
    assert line_b.length_px == 1000.0
    assert line_b.length_scaled == pytest.approx(93.75)
    assert line_b.key == ""  # GroupID 100 absent du catalogue
    assert (perim.n_segments, perim.length_px) == (2, 200.0)
    assert perim.length_scaled == pytest.approx(18.75)


def test_catalog_lookup(mini_doc):
    cat = load_catalog(mini_doc.root)
    assert set(cat) == {97}
    assert cat[97].key == "19PE0.75 #12"
    assert cat[97].description == "conduit 3/4 03c12"
    assert cat[97].name == "conduit 3/4 03c12"


def test_inventory_exports(mini_doc, tmp_path):
    rows = build_inventory(mini_doc)
    csv_path = write_csv(rows, tmp_path / "inv.csv")
    raw = csv_path.read_bytes()
    assert raw.startswith(b"\xef\xbb\xbf") and b"\r\n" in raw
    with csv_path.open(encoding="utf-8-sig", newline="") as fh:
        table = list(csv.reader(fh, delimiter=";"))
    assert table[0] == FIELDS
    assert len(table) == 1 + len(rows)
    assert table[6][FIELDS.index("length_scaled")] == "93,75"  # virgule décimale (Excel FR)
    data = json.loads(write_json(rows, tmp_path / "inv.json").read_text(encoding="utf-8"))
    assert len(data["rows"]) == len(rows) and "À CONFIRMER" in data["length_scaled_note"]
