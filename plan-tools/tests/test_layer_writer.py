import hashlib
import shutil

import pytest

from plan_tools.inventory import build_inventory
from plan_tools.layer_writer import (
    LAYER_NAME,
    LINE_DEFAULTS,
    build_ia_doc,
    ia_path,
    write_ia_qpl,
)
from plan_tools.qpl_io import load, loads, roundtrip_check, serialize
from plan_tools.route import route_doc

BARE = (
    b'<?xml version="1.0"?>\r\n<QuoterPlanSession>\r\n\t<Plans>\r\n'
    b'\t\t<Plan Name="P" FileName="p.png">\r\n\t\t\t<Layers>\r\n'
    b'\t\t\t\t<Layer Index="0" Name="L" Opacity="150" Visible="True" Active="True">\r\n'
    b'\t\t\t\t\t<Counter Name="PANNEAU" GroupID="1" Visible="True">\r\n'
    b'\t\t\t\t\t\t<Element X="0" Y="0" Width="10" Height="10"/>\r\n'
    b"\t\t\t\t\t</Counter>\r\n"
    b'\t\t\t\t\t<Counter Name="PRISE" GroupID="2" Visible="True">\r\n'
    b'\t\t\t\t\t\t<Element X="95" Y="45" Width="10" Height="10"/>\r\n'
    b"\t\t\t\t\t</Counter>\r\n"
    b"\t\t\t\t</Layer>\r\n\t\t\t</Layers>\r\n\t\t</Plan>\r\n\t</Plans>\r\n"
    b"</QuoterPlanSession>\r\n"
)


def _ia_layers(root):
    return [la for la in root.iterfind("Plans/Plan/Layers/Layer") if la.get("Name") == LAYER_NAME]


def _strip_ia(root):
    """Retire les calques IA en restaurant les blancs : doit redonner l'original exact."""
    for layer in _ia_layers(root):
        prev = layer.getprevious()
        prev.tail = layer.tail
        layer.getparent().remove(layer)


def test_only_new_layers_are_added(rdoc, cfg):
    new, added = build_ia_doc(rdoc, route_doc(rdoc, cfg), cfg)
    assert added == 2  # Plan A et Plan B ; Plan C (aucun appareil) intact
    assert serialize(new) != rdoc.raw
    _strip_ia(new.root)
    assert serialize(new) == rdoc.raw  # tout le reste identique à l'octet
    assert not rdoc.is_modified()  # l'arbre d'origine n'a pas été touché


def test_layer_and_line_attributes(rdoc, cfg):
    new, _ = build_ia_doc(rdoc, route_doc(rdoc, cfg), cfg)
    layer_a, layer_b = _ia_layers(new.root)
    assert list(layer_a.attrib.items()) == [
        ("Index", "2"),
        ("Name", "IA - Conduits"),
        ("Opacity", "150"),
        ("Visible", "True"),
        ("Active", "False"),
    ]
    assert layer_b.get("Index") == "1"
    lines = list(layer_a.iterchildren("Line"))
    assert [ln.get("Name") for ln in lines] == [
        "IA conduit 3/4 – L1",
        "IA conduit 3/4 – groupe 1",
        "IA conduit 3/4 – groupe 2",
    ]
    # attributs clonés de la Line « conduit 3/4 03c12 » ; GroupID du groupe 3/4 (pas le 100)
    assert list(lines[0].attrib.items()) == [
        ("Name", "IA conduit 3/4 – L1"),
        ("GroupID", "97"),
        ("Color", "-65281"),
        ("PenWidth", "1"),
        ("PenType", "Generic"),
        ("ShowMeasure", "False"),
        ("Visible", "True"),
    ]


def test_serialized_style_matches_plan_expert(rdoc, cfg):
    new, _ = build_ia_doc(rdoc, route_doc(rdoc, cfg), cfg)
    out = serialize(new)
    block = (
        "\t\t\t\t</Layer>\r\n"
        '\t\t\t\t<Layer Index="1" Name="IA - Conduits" Opacity="150" Visible="True" '
        'Active="False">\r\n'
        '\t\t\t\t\t<Line Name="IA conduit 3/4 – groupe 1" GroupID="97" Color="-65281" '
        'PenWidth="1" PenType="Generic" ShowMeasure="False" Visible="True">\r\n'
        '\t\t\t\t\t\t<Element X1="900" Y1="500" X2="500" Y2="500" />\r\n'
        '\t\t\t\t\t\t<Element X1="500" Y1="500" X2="500" Y2="900" />\r\n'
        '\t\t\t\t\t\t<Element X1="500" Y1="900" X2="900" Y2="900" />\r\n'
        "\t\t\t\t\t</Line>\r\n"
        "\t\t\t\t</Layer>\r\n"
        "\t\t\t</Layers>\r\n"
    ).encode()
    assert block in out


def test_write_roundtrips_and_inventory_unchanged(rdoc, cfg, tmp_path):
    routes = route_doc(rdoc, cfg)
    dest, added = write_ia_qpl(rdoc, routes, ia_path(rdoc.path, tmp_path), cfg)
    assert dest.name == "route - IA.qpl" and added == 2
    r = roundtrip_check(dest)
    assert r.byte_equal and r.c14n_equal
    before = build_inventory(rdoc)
    after = build_inventory(load(dest))
    ia_rows = [row for row in after if row.layer == LAYER_NAME]
    assert [row for row in after if row.layer != LAYER_NAME] == before
    assert len(ia_rows) == sum(len([x for x in p.runs if x.segments]) for p in routes)
    assert all(row.kind == "Line" and row.key == "19PE0.75 #12" for row in ia_rows)
    assert sum(row.length_px for row in ia_rows) == sum(p.length_px for p in routes)


def test_never_overwrites(rdoc, cfg, route_path, tmp_path):
    original = hashlib.sha256(route_path.read_bytes()).hexdigest()
    routes = route_doc(rdoc, cfg)
    dest = tmp_path / "x - IA.qpl"
    write_ia_qpl(rdoc, routes, dest, cfg)
    first = dest.read_bytes()
    with pytest.raises(FileExistsError, match="--force"):
        write_ia_qpl(rdoc, routes, dest, cfg)
    assert dest.read_bytes() == first
    write_ia_qpl(rdoc, routes, dest, cfg, force=True)
    assert dest.read_bytes() == first
    copy = tmp_path / "copie.qpl"
    shutil.copy(route_path, copy)
    doc = load(copy)
    with pytest.raises(ValueError, match="jamais écrasé"):
        write_ia_qpl(doc, routes, copy, cfg, force=True)
    assert copy.read_bytes() == route_path.read_bytes()
    assert hashlib.sha256(route_path.read_bytes()).hexdigest() == original


def test_defaults_without_conduit_group_or_line(cfg):
    doc = loads(BARE)
    new, added = build_ia_doc(doc, route_doc(doc, cfg), cfg)
    assert added == 1
    (line,) = _ia_layers(new.root)[0].iterchildren("Line")
    assert "GroupID" not in line.attrib
    assert dict(line.attrib) == {**LINE_DEFAULTS, "Name": "IA conduit 3/4 – groupe 1"}
    assert [dict(e.attrib) for e in line] == [
        {"X1": "5", "Y1": "5", "X2": "100", "Y2": "5"},
        {"X1": "100", "Y1": "5", "X2": "100", "Y2": "50"},
    ]
    out = serialize(new)
    assert serialize(loads(out)) == out
    assert b'\t\t\t\t<Layer Index="1" Name="IA - Conduits"' in out
