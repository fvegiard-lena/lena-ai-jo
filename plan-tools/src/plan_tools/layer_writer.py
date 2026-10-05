"""Écriture de « <nom> - IA.qpl » : copie du document + un calque « IA - Conduits » par plan tracé.

Le document d'origine n'est jamais modifié : on travaille sur une copie profonde de l'arbre et
on n'y ajoute que les nouveaux calques (avec l'indentation tabulée de Plan Expert). Le reste du
fichier ressort à l'octet près grâce au sérialiseur de qpl_io.
"""

from __future__ import annotations

import copy
from collections.abc import Sequence
from pathlib import Path

from lxml import etree

from .catalog import load_catalog
from .classify import Config
from .model import to_int
from .qpl_io import QplDoc, loads, serialize
from .route import PlanRoute, Run

LAYER_NAME = "IA - Conduits"
IA_COLOR = "-65281"  # magenta, entier ARGB signé .NET
LINE_DEFAULTS = {
    "Name": "",
    "Color": IA_COLOR,
    "PenWidth": "2",
    "PenType": "Generic",
    "ShowMeasure": "True",
    "Visible": "True",
}


def ia_path(qpl: Path, out_dir: Path) -> Path:
    return out_dir / f"{qpl.stem} - IA.qpl"


def line_name(tag: str) -> str:
    return f"IA conduit 3/4 – {tag}"


def conduit_group_id(root: etree._Element, cfg: Config) -> int | None:
    """GroupID du 1er article du catalogue dont la description correspond à `conduit_group`."""
    for gid, entry in load_catalog(root).items():
        if cfg.conduit_group.search(entry.description):
            return gid
    return None


def template_line(root: etree._Element, gid: int | None, cfg: Config) -> etree._Element | None:
    """Line modèle : même GroupID que le conduit retenu, sinon nommée « conduit », sinon la 1re."""
    lines = list(root.iterfind("Plans/Plan/Layers/Layer/Line"))
    same_group = [ln for ln in lines if gid is not None and to_int(ln.get("GroupID")) == gid]
    named = [ln for ln in lines if cfg.conduit_line.search(ln.get("Name", ""))]
    return next(iter(same_group + named + lines), None)


def line_attrs(template: etree._Element | None, name: str, gid: int | None) -> dict[str, str]:
    """Attributs clonés du modèle (ordre conservé) ; Name, GroupID, Color et Visible imposés."""
    src = dict(template.attrib) if template is not None else LINE_DEFAULTS
    out = {"Name": name}
    if gid is not None:
        out["GroupID"] = str(gid)
    out.update((k, v) for k, v in src.items() if k not in ("Name", "GroupID"))
    out["Color"] = IA_COLOR
    out["Visible"] = "True"
    return out


def _indent_of(el: etree._Element) -> str:
    prev = el.getprevious()
    ws = prev.tail if prev is not None else el.getparent().text
    return ws.rsplit("\n", 1)[-1] if ws and "\n" in ws else ""


def _ia_layer(
    index: int, runs: Sequence[Run], attrs: dict[str, dict[str, str]], indent: str
) -> etree._Element:
    """<Layer> IA indenté comme Plan Expert : `indent` = indentation du calque lui-même."""
    layer = etree.Element(
        "Layer",
        {
            "Index": str(index),
            "Name": LAYER_NAME,
            "Opacity": "150",
            "Visible": "True",
            "Active": "False",
        },
    )
    layer.text = "\n" + indent + "\t"
    for run in runs:
        line = etree.SubElement(layer, "Line", attrs[run.tag])
        line.text = "\n" + indent + "\t\t"
        for x1, y1, x2, y2 in run.segments:
            e = etree.SubElement(
                line, "Element", {"X1": str(x1), "Y1": str(y1), "X2": str(x2), "Y2": str(y2)}
            )
            e.tail = "\n" + indent + "\t\t"
        line[-1].tail = "\n" + indent + "\t"
        line.tail = "\n" + indent + "\t"
    layer[-1].tail = "\n" + indent
    return layer


def _append_layer(layers_el: etree._Element, layer: etree._Element, indent: str) -> None:
    if len(layers_el):
        last = layers_el[-1]
        layer.tail, last.tail = last.tail, "\n" + indent
    else:
        layers_el.text = "\n" + indent
        layer.tail = "\n" + _indent_of(layers_el)
    layers_el.append(layer)


def build_ia_doc(doc: QplDoc, routes: Sequence[PlanRoute], cfg: Config) -> tuple[QplDoc, int]:
    """Copie du document avec un calque « IA - Conduits » par plan tracé ; (doc, nb calques)."""
    root = copy.deepcopy(doc.root)
    gid = conduit_group_id(root, cfg)
    template = template_line(root, gid, cfg)
    plans_el = root.find("Plans")
    plan_els = list(plans_el.iterchildren("Plan")) if plans_el is not None else []
    added = 0
    for route in routes:
        runs = [r for r in route.runs if r.segments]
        layers_el = plan_els[route.index].find("Layers") if route.index < len(plan_els) else None
        if not runs or layers_el is None:
            continue
        indices = [to_int(la.get("Index")) for la in layers_el.iterchildren("Layer")]
        index = max((i for i in indices if i is not None), default=-1) + 1
        indent = _indent_of(layers_el) + "\t"
        attrs = {r.tag: line_attrs(template, line_name(r.tag), gid) for r in runs}
        _append_layer(layers_el, _ia_layer(index, runs, attrs, indent), indent)
        added += 1
    new = QplDoc(
        path=None,
        raw=doc.raw,
        tree=etree.ElementTree(root),
        prolog=doc.prolog,
        epilog=doc.epilog,
        newline=doc.newline,
        _c14n_digest=doc._c14n_digest,
    )
    return new, added


def write_ia_qpl(
    doc: QplDoc, routes: Sequence[PlanRoute], dest: Path, cfg: Config, force: bool = False
) -> tuple[Path, int]:
    """Écrit la copie IA. Refuse d'écraser un fichier existant (sauf `force`) et refuse
    toujours d'écrire sur le .qpl d'origine."""
    if doc.path is not None and dest.resolve() == Path(doc.path).resolve():
        raise ValueError(f"refus : « {dest} » est le .qpl d'origine, il ne sera jamais écrasé.")
    if dest.exists() and not force:
        raise FileExistsError(f"« {dest} » existe déjà : relancer avec --force pour le remplacer.")
    new, added = build_ia_doc(doc, routes, cfg)
    out = serialize(new)
    if serialize(loads(out)) != out:  # le résultat doit se relire et se réécrire à l'identique
        raise RuntimeError("la copie IA ne passe pas l'aller-retour qpl_io ; rien n'est écrit.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("wb" if force else "xb") as fh:
        fh.write(out)
    return dest, added
