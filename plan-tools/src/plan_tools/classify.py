"""Classement des symboles (Counter) : rôle panneau / appareil / ignoré, et groupes de circuit.

Les règles viennent de `config.toml` (racine du projet plan-tools) ; autre fichier possible
via la variable d'environnement PLAN_TOOLS_CONFIG.
"""

from __future__ import annotations

import os
import re
import tomllib
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from lxml import etree

from .model import Point

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config.toml"
ENV_CONFIG = "PLAN_TOOLS_CONFIG"
ROLES = ("panel", "device", "ignore")


@dataclass(frozen=True)
class Config:
    panel: re.Pattern[str]
    panel_exclude: re.Pattern[str]
    ignore: re.Pattern[str]
    device: re.Pattern[str]
    tag: re.Pattern[str]
    max_devices_per_run: int
    conduit_line: re.Pattern[str]
    conduit_group: re.Pattern[str]
    overlap_tolerance_px: float


def load_config(path: str | Path | None = None) -> Config:
    p = Path(path or os.environ.get(ENV_CONFIG) or CONFIG_PATH)
    with p.open("rb") as fh:
        raw = tomllib.load(fh)
    cls, circ, rte = raw["classify"], raw["circuit"], raw["route"]
    max_n = int(circ["max_devices_per_run"])
    if max_n < 1:
        raise ValueError(f"max_devices_per_run doit être ≥ 1 (lu : {max_n}) dans « {p} ».")
    return Config(
        panel=re.compile(cls["panel"]),
        panel_exclude=re.compile(cls.get("panel_exclude", "(?!)")),  # (?!) : ne trouve rien
        ignore=re.compile(cls["ignore"]),
        device=re.compile(cls["device"]),
        tag=re.compile(circ["tag"]),
        max_devices_per_run=max_n,
        conduit_line=re.compile(rte["conduit_line"]),
        conduit_group=re.compile(rte["conduit_group"]),
        overlap_tolerance_px=float(rte["overlap_tolerance_px"]),
    )


def classify(name: str, cfg: Config) -> str:
    """Rôle d'un nom de Counter, évalué dans l'ordre : « ignore » (à enlever / existant),
    « panel » (sauf `panel_exclude`), « device »."""
    if cfg.ignore.search(name):
        return "ignore"
    if cfg.panel.search(name) and not cfg.panel_exclude.search(name):
        return "panel"
    return "device" if cfg.device.search(name) else "ignore"


def circuit_tag(name: str, text: str | None, cfg: Config) -> str | None:
    """Étiquette de circuit trouvée dans @Name, sinon dans @Text ; None si aucune."""
    for source in (name, text or ""):
        m = cfg.tag.search(source)
        if m:
            return m.group(0)
    return None


def manhattan(a: Point, b: Point) -> float:
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def proximity_clusters(points: Sequence[Point], max_n: int) -> list[list[int]]:
    """Regroupe des points par proximité (plus proche voisin glouton, distance de Manhattan).

    Germe = point non affecté le plus en haut à gauche ; on ajoute ensuite le point non affecté
    le plus proche d'un membre du groupe jusqu'à `max_n`. Déterministe (égalités : ordre y, x).
    Renvoie des listes d'indices dans `points`.
    """
    order = sorted(range(len(points)), key=lambda i: (points[i][1], points[i][0], i))
    unassigned = dict.fromkeys(order)  # ensemble ordonné
    clusters: list[list[int]] = []
    while unassigned:
        seed = next(iter(unassigned))
        del unassigned[seed]
        cluster = [seed]
        best = {i: manhattan(points[i], points[seed]) for i in unassigned}
        while len(cluster) < max_n and best:
            nxt = min(best, key=best.__getitem__)  # 1er minimum dans l'ordre (y, x)
            del best[nxt], unassigned[nxt]
            cluster.append(nxt)
            for i in best:
                d = manhattan(points[i], points[nxt])
                if d < best[i]:
                    best[i] = d
        clusters.append(cluster)
    return clusters


def counter_names(root: etree._Element) -> tuple[Counter[str], Counter[str]]:
    """(symboles par nom, objets Counter par nom) pour les plans sous <Plans>."""
    symbols: Counter[str] = Counter()
    items: Counter[str] = Counter()
    for c in root.iterfind("Plans/Plan/Layers/Layer/Counter"):
        name = c.get("Name", "")
        symbols[name] += sum(1 for _ in c.iterchildren("Element"))
        items[name] += 1
    return symbols, items


@dataclass(frozen=True)
class RoleRow:
    role: str
    name: str
    symbols: int
    items: int
    tag: str | None


def classify_report(root: etree._Element, cfg: Config) -> list[RoleRow]:
    """Tableau des noms de Counter du document avec leur rôle (pour validation par Jo)."""
    symbols, items = counter_names(root)
    rows = [
        RoleRow(classify(n, cfg), n, symbols[n], items[n], circuit_tag(n, None, cfg))
        for n in symbols
    ]
    rows.sort(key=lambda r: (ROLES.index(r.role), -r.symbols, r.name))
    return rows
