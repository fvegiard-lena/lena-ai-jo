"""Vues légères (dataclasses) sur l'arbre .qpl : plans, calques, objets de relevé."""

from __future__ import annotations

import math
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from lxml import etree

KINDS = ("Counter", "Line", "Perimeter", "Area", "Rectangle", "Legend", "Note", "Angle")
LENGTH_KINDS = ("Line", "Perimeter", "Area")

Point = tuple[float, float]


@dataclass(frozen=True)
class Item:
    kind: str
    name: str
    group_id: int | None
    color: int | None
    visible: bool
    count: int  # nombre de <Element> (symboles pour un Counter) ; 1 pour les annotations
    n_segments: int
    length_px: float
    area_px2: float | None


@dataclass(frozen=True)
class Layer:
    index: int
    name: str
    items: tuple[Item, ...]


@dataclass(frozen=True)
class Plan:
    name: str
    filename: str
    scale_value: float
    scale_raw: str
    layers: tuple[Layer, ...]


def to_float(value: str | None) -> float:
    """Convertit un nombre .qpl ; accepte la virgule décimale française (« 0,125 »)."""
    if not value:
        return 0.0
    try:
        return float(value.replace(",", "."))
    except ValueError:
        return 0.0


def to_int(value: str | None) -> int | None:
    try:
        return int(value) if value not in (None, "") else None
    except ValueError:
        return None


def segment_length(x1: float, y1: float, x2: float, y2: float) -> float:
    return math.hypot(x2 - x1, y2 - y1)


def polyline_length(points: Sequence[Point], closed: bool = False) -> float:
    """Longueur d'une polyligne ; `closed` n'ajoute le segment de fermeture qu'à partir de
    3 points (à 2 points, il doublerait l'unique segment)."""
    pts = list(points) + ([points[0]] if closed and len(points) > 2 else [])
    return sum(segment_length(*a, *b) for a, b in zip(pts, pts[1:], strict=False))


def polygon_area(points: Sequence[Point]) -> float:
    """Aire d'un polygone par la formule du lacet (shoelace), en px²."""
    n = len(points)
    s = sum(
        points[i][0] * points[(i + 1) % n][1] - points[(i + 1) % n][0] * points[i][1]
        for i in range(n)
    )
    return abs(s) / 2.0


def _points(el: etree._Element) -> list[Point]:
    return [(to_float(p.get("X")), to_float(p.get("Y"))) for p in el.iterchildren("Point")]


def item_from_element(el: etree._Element) -> Item:
    kind = el.tag
    elements = list(el.iterchildren("Element"))
    count, n_seg, length, area = len(elements), 0, 0.0, None
    if kind == "Line":
        segs = [tuple(to_float(e.get(k)) for k in ("X1", "Y1", "X2", "Y2")) for e in elements]
        n_seg, length = len(segs), sum(segment_length(*s) for s in segs)
    elif kind == "Perimeter":
        for e in elements:
            pts, closed = _points(e), e.get("Closed") == "True"
            n_seg += max(len(pts) - 1, 0) + (1 if closed and len(pts) > 2 else 0)
            length += polyline_length(pts, closed)
    elif kind == "Area":
        area = 0.0
        for e in elements:
            pts = _points(e)
            n_seg += len(pts) if len(pts) > 2 else 0
            length += polyline_length(pts, closed=True)
            area += polygon_area(pts)
    elif kind != "Counter":
        count = 1
    return Item(
        kind=kind,
        name=el.get("Name", ""),
        group_id=to_int(el.get("GroupID")),
        color=to_int(el.get("Color")),
        visible=el.get("Visible", "True") == "True",
        count=count,
        n_segments=n_seg,
        length_px=length,
        area_px2=area,
    )


def _plan_elements(root: etree._Element) -> Iterable[etree._Element]:
    plans_el = root.find("Plans")
    return plans_el.iterchildren("Plan") if plans_el is not None else ()


def plans(root: etree._Element) -> list[Plan]:
    """Plans du projet (uniquement sous <Plans>, pas les <Plan> de <Workspace>)."""
    result = []
    for p in _plan_elements(root):
        scale = p.find("Scale")
        scale_raw = scale.get("Value", "0") if scale is not None else "0"
        layers = tuple(
            Layer(
                index=to_int(layer.get("Index")) or 0,
                name=layer.get("Name", ""),
                items=tuple(item_from_element(c) for c in layer if isinstance(c.tag, str)),
            )
            for layer in p.iterfind("Layers/Layer")
        )
        result.append(
            Plan(
                name=p.get("Name", ""),
                filename=p.get("FileName", ""),
                scale_value=to_float(scale_raw),
                scale_raw=scale_raw,
                layers=layers,
            )
        )
    return result
