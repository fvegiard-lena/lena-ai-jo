"""Tracé géométrique des conduits (Manhattan, sans image) : panneau → appareils de chaque groupe.

Pour chaque plan : symboles classés (classify.py), appareils groupés par étiquette de circuit
puis par proximité, chaque groupe chaîné au plus proche voisin depuis le panneau le plus proche ;
chaque saut est un chemin en L (deux segments horizontaux / verticaux).
"""

from __future__ import annotations

import re
from collections import defaultdict
from collections.abc import Sequence
from dataclasses import dataclass

from lxml import etree

from .catalog import CatalogEntry, load_catalog
from .classify import Config, circuit_tag, classify, manhattan, proximity_clusters
from .model import Point, to_float, to_int
from .qpl_io import QplDoc

Segment = tuple[int, int, int, int]
NO_PANEL = "[À CONFIRMER — Jo] aucun panneau détecté"


@dataclass(frozen=True)
class Device:
    name: str
    x: int  # centre du symbole, en px de l'image du plan
    y: int
    tag: str | None

    @property
    def center(self) -> Point:
        return (self.x, self.y)


@dataclass(frozen=True)
class Run:
    tag: str
    segments: tuple[Segment, ...]
    length_px: float
    devices: tuple[Device, ...]  # dans l'ordre de passage
    start: Point
    from_panel: bool


@dataclass(frozen=True)
class PlanRoute:
    index: int  # position du <Plan> sous <Plans>
    name: str
    filename: str
    scale_value: float
    panels: tuple[Point, ...]
    runs: tuple[Run, ...]
    flags: tuple[str, ...]
    n_ignored: int

    @property
    def length_px(self) -> float:
        return sum(r.length_px for r in self.runs)

    @property
    def n_devices(self) -> int:
        return sum(len(r.devices) for r in self.runs)


class _Occupancy:
    """Segments déjà posés (conduits existants + tracés IA), indexés par axe et par bande."""

    def __init__(self, tol: float) -> None:
        self.tol = tol
        self.step = max(tol, 1.0)
        self.bands: dict[str, defaultdict[int, list[tuple[float, float, float]]]] = {
            "h": defaultdict(list),
            "v": defaultdict(list),
        }

    def _axis(self, seg: Sequence[float]) -> tuple[str, float, float, float] | None:
        x1, y1, x2, y2 = seg
        if abs(y1 - y2) <= self.tol:
            return "h", (y1 + y2) / 2, min(x1, x2), max(x1, x2)
        if abs(x1 - x2) <= self.tol:
            return "v", (x1 + x2) / 2, min(y1, y2), max(y1, y2)
        return None  # segment oblique : ignoré

    def add(self, seg: Sequence[float]) -> None:
        a = self._axis(seg)
        if a is not None:
            axis, c, lo, hi = a
            self.bands[axis][int(c // self.step)].append((c, lo, hi))

    def overlap(self, seg: Sequence[float]) -> float:
        """Longueur de `seg` superposée (à `tol` px près) aux segments parallèles déjà posés."""
        a = self._axis(seg)
        if a is None:
            return 0.0
        axis, c, lo, hi = a
        bands, total = self.bands[axis], 0.0
        for k in range(int((c - self.tol) // self.step), int((c + self.tol) // self.step) + 1):
            for c2, lo2, hi2 in bands.get(k, ()):
                if abs(c - c2) <= self.tol:
                    total += max(0.0, min(hi, hi2) - max(lo, lo2))
        return total


def l_path(a: Point, b: Point, occupied: _Occupancy | None = None) -> list[Segment]:
    """Chemin en L de a à b : horizontal d'abord, sauf si le coude « vertical d'abord » se
    superpose moins aux conduits déjà posés. Segments de longueur nulle supprimés."""
    (x0, y0), (x1, y1) = (int(a[0]), int(a[1])), (int(b[0]), int(b[1]))
    h_first = [s for s in ((x0, y0, x1, y0), (x1, y0, x1, y1)) if s[:2] != s[2:]]
    v_first = [s for s in ((x0, y0, x0, y1), (x0, y1, x1, y1)) if s[:2] != s[2:]]
    if occupied is not None:
        if sum(map(occupied.overlap, v_first)) < sum(map(occupied.overlap, h_first)):
            return v_first
    return h_first


def _visible(el: etree._Element) -> bool:
    return el.get("Visible", "True") != "False"


def extract_symbols(
    plan_el: etree._Element, cfg: Config
) -> tuple[list[Point], list[Device], int, int]:
    """(centres des panneaux, appareils, nb symboles ignorés, nb symboles masqués)."""
    panels: list[Point] = []
    devices: list[Device] = []
    ignored = hidden = 0
    for layer in plan_el.iterfind("Layers/Layer"):
        for counter in layer.iterchildren("Counter"):
            elements = list(counter.iterchildren("Element"))
            if not (_visible(layer) and _visible(counter)):
                hidden += len(elements)
                continue
            name = counter.get("Name", "")
            role = classify(name, cfg)
            if role == "ignore":
                ignored += len(elements)
                continue
            tag = circuit_tag(name, counter.get("Text"), cfg)
            for e in elements:
                x, y, w, h = (to_float(e.get(k)) for k in ("X", "Y", "Width", "Height"))
                cx, cy = round(x + w / 2), round(y + h / 2)
                if role == "panel":
                    panels.append((cx, cy))
                else:
                    devices.append(Device(name, cx, cy, tag))
    return panels, devices, ignored, hidden


def conduit_segments(
    plan_el: etree._Element, catalog: dict[int, CatalogEntry], cfg: Config
) -> list[tuple[float, float, float, float]]:
    """Segments des Line existantes reconnues comme conduits (nom ou description catalogue)."""
    segs = []
    for line in plan_el.iterfind("Layers/Layer/Line"):
        gid = to_int(line.get("GroupID"))
        entry = catalog.get(gid) if gid is not None else None
        label = f"{line.get('Name', '')} {entry.description if entry else ''}"
        if not cfg.conduit_line.search(label):
            continue
        for e in line.iterchildren("Element"):
            x1, y1, x2, y2 = (to_float(e.get(k)) for k in ("X1", "Y1", "X2", "Y2"))
            segs.append((x1, y1, x2, y2))
    return segs


def group_devices(
    devices: Sequence[Device], cfg: Config
) -> tuple[list[tuple[str, list[Device]]], list[str]]:
    """Groupes (étiquette, appareils) + drapeaux. Étiquetés d'abord (ordre alphabétique),
    scindés par proximité au-delà de `max_devices_per_run` ; puis « groupe n » par proximité."""
    max_n = cfg.max_devices_per_run
    by_tag: dict[str, list[Device]] = defaultdict(list)
    untagged: list[Device] = []
    for d in devices:
        (by_tag[d.tag] if d.tag else untagged).append(d)
    groups: list[tuple[str, list[Device]]] = []
    flags: list[str] = []
    for tag in sorted(by_tag):
        members = by_tag[tag]
        if len(members) <= max_n:
            groups.append((tag, members))
            continue
        parts = proximity_clusters([m.center for m in members], max_n)
        flags.append(
            f"[À CONFIRMER — Jo] étiquette {tag} : {len(members)} appareils > {max_n}, "
            f"scindée en {len(parts)} parcours ({tag}.1 …)"
        )
        groups += [(f"{tag}.{k}", [members[i] for i in idx]) for k, idx in enumerate(parts, 1)]
    parts = proximity_clusters([d.center for d in untagged], max_n)
    groups += [(f"groupe {k}", [untagged[i] for i in idx]) for k, idx in enumerate(parts, 1)]
    return groups, flags


def chain(start: Point, devices: Sequence[Device]) -> list[Device]:
    """Ordre de passage glouton (plus proche voisin, Manhattan) depuis `start`."""
    left = sorted(devices, key=lambda d: (d.y, d.x, d.name))
    order: list[Device] = []
    cur = start
    while left:
        i = min(range(len(left)), key=lambda k: manhattan(cur, left[k].center))
        order.append(left.pop(i))
        cur = order[-1].center
    return order


def route_group(
    tag: str, devices: Sequence[Device], panels: Sequence[Point], occupied: _Occupancy
) -> Run:
    """Parcours d'un groupe : départ au panneau le plus proche du centre du groupe ou, sans
    panneau, à l'appareil le plus proche de ce centre."""
    centroid = (
        sum(d.x for d in devices) / len(devices),
        sum(d.y for d in devices) / len(devices),
    )
    if panels:
        start = min(panels, key=lambda p: (manhattan(p, centroid), p))
    else:
        start = min(devices, key=lambda d: (manhattan(d.center, centroid), d.y, d.x)).center
    ordered = chain(start, devices)
    segments: list[Segment] = []
    cur = start
    for d in ordered:
        hop = l_path(cur, d.center, occupied)
        for s in hop:
            occupied.add(s)
        segments += hop
        cur = d.center
    length = float(sum(abs(x2 - x1) + abs(y2 - y1) for x1, y1, x2, y2 in segments))
    return Run(tag, tuple(segments), length, tuple(ordered), start, bool(panels))


def route_plan(
    plan_el: etree._Element, index: int, catalog: dict[int, CatalogEntry], cfg: Config
) -> PlanRoute:
    panels, devices, ignored, hidden = extract_symbols(plan_el, cfg)
    occupied = _Occupancy(cfg.overlap_tolerance_px)
    for seg in conduit_segments(plan_el, catalog, cfg):
        occupied.add(seg)
    runs: list[Run] = []
    flags: list[str] = []
    if devices:
        if not panels:
            flags.append(f"{NO_PANEL} : chaque parcours part de l'appareil le plus central")
        elif len(panels) > 1:
            flags.append(
                f"[À CONFIRMER — Jo] {len(panels)} panneaux : chaque parcours part du plus proche"
            )
        groups, group_flags = group_devices(devices, cfg)
        flags += group_flags
        runs = [route_group(tag, members, panels, occupied) for tag, members in groups]
    if hidden:
        flags.append(f"{hidden} symbole(s) masqué(s) (Visible=False) non relié(s)")
    scale = plan_el.find("Scale")
    return PlanRoute(
        index=index,
        name=plan_el.get("Name", ""),
        filename=plan_el.get("FileName", ""),
        scale_value=to_float(scale.get("Value")) if scale is not None else 0.0,
        panels=tuple(panels),
        runs=tuple(runs),
        flags=tuple(flags),
        n_ignored=ignored,
    )


def match_plans(names: Sequence[str], pattern: str | None) -> list[int]:
    """Indices des plans dont le nom contient `pattern` (sans casse). Les correspondances
    « mot entier » sont préférées (« R1 - 1 » ne prend pas « R1 - 10 ») ; sinon sous-chaîne."""
    if not pattern or not pattern.strip():
        return list(range(len(names)))
    p = pattern.strip()
    word = re.compile(rf"(?<!\w){re.escape(p)}(?!\w)", re.IGNORECASE)
    hits = [i for i, n in enumerate(names) if word.search(n)]
    return hits or [i for i, n in enumerate(names) if p.casefold() in n.casefold()]


def wall_aware_unavailable() -> None:
    """`--wall-aware` : NON IMPLÉMENTÉ, volontairement (aucun repli factice).

    Piste étudiée : masque des pixels sombres du PNG sous-échantillonné (seuil numpy) puis
    `skimage.graph.route_through_array(fully_connected=False)` pour chaque saut. Écartée en v1 :
    1. le MCP de scikit-image n'a pas de pénalité de virage : en zone uniforme, tous les
       escaliers 4-connexes ont le même coût, d'où des dizaines de micro-segments par saut,
       inutilisables comme conduits Plan Expert (segments droits attendus) ;
    2. le masque « sombre » mélange murs, texte, cotes, hachures et symboles : éviter tout ce
       qui est noir n'est pas « suivre les murs » ;
    3. plans de 50 à 120 Mpx et ~1 000 sauts par plan : il faut découper et sous-échantillonner,
       donc perdre plusieurs dizaines de px de précision.
    Prérequis d'une v2 : détection des murs + routage sur grille avec coût de virage.
    """
    raise NotImplementedError(
        "--wall-aware n'est pas encore implémenté (v1 = tracé géométrique en L) ; "
        "voir route.wall_aware_unavailable."
    )


def route_doc(
    doc: QplDoc, cfg: Config, plan_filter: str | None = None, wall_aware: bool = False
) -> list[PlanRoute]:
    """Trace tous les plans (ou ceux qui correspondent à `plan_filter`). Lecture seule."""
    if wall_aware:
        wall_aware_unavailable()
    plans_el = doc.root.find("Plans")
    plan_els = list(plans_el.iterchildren("Plan")) if plans_el is not None else []
    catalog = load_catalog(doc.root)
    selected = match_plans([p.get("Name", "") for p in plan_els], plan_filter)
    return [route_plan(plan_els[i], i, catalog, cfg) for i in selected]
