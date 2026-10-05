"""Inventaire : une ligne par (plan, calque, objet), export JSON + CSV (Excel FR)."""

from __future__ import annotations

import csv
import json
from dataclasses import asdict, dataclass, fields
from datetime import datetime
from pathlib import Path

from .catalog import load_catalog
from .model import LENGTH_KINDS, plans
from .qpl_io import QplDoc

SCALE_FLAG = "[À CONFIRMER — Jo] unité d'échelle"


@dataclass(frozen=True)
class InventoryRow:
    plan: str
    layer_index: int
    layer: str
    kind: str
    name: str
    group_id: int | None
    key: str
    description: str
    count: int
    n_segments: int
    length_px: float
    length_scaled: float | None
    area_px2: float | None
    scale_value: float
    filename: str


FIELDS = [f.name for f in fields(InventoryRow)]


def build_inventory(doc: QplDoc) -> list[InventoryRow]:
    catalog = load_catalog(doc.root)
    rows = []
    for plan in plans(doc.root):
        for layer in plan.layers:
            for it in layer.items:
                entry = catalog.get(it.group_id) if it.group_id is not None else None
                scaled = (
                    it.length_px * plan.scale_value
                    if plan.scale_value > 0 and it.kind in LENGTH_KINDS
                    else None
                )
                rows.append(
                    InventoryRow(
                        plan=plan.name,
                        layer_index=layer.index,
                        layer=layer.name,
                        kind=it.kind,
                        name=it.name,
                        group_id=it.group_id,
                        key=entry.key if entry else "",
                        description=entry.description if entry else "",
                        count=it.count,
                        n_segments=it.n_segments,
                        length_px=round(it.length_px, 2),
                        length_scaled=round(scaled, 4) if scaled is not None else None,
                        area_px2=round(it.area_px2, 2) if it.area_px2 is not None else None,
                        scale_value=plan.scale_value,
                        filename=plan.filename,
                    )
                )
    return rows


def fmt_num(value: float | int | None) -> str:
    """Nombre pour Excel FR : virgule décimale, vide si None."""
    if value is None:
        return ""
    if isinstance(value, int) or float(value).is_integer():
        return str(int(value))
    return f"{value:.6f}".rstrip("0").rstrip(".").replace(".", ",")


def _cell(value: object) -> str:
    if value is None or isinstance(value, int | float):
        return fmt_num(value)  # type: ignore[arg-type]
    return str(value)


def write_csv(rows: list[InventoryRow], path: Path) -> Path:
    """CSV UTF-8 avec BOM, séparateur « ; », virgule décimale (ouvre direct dans Excel FR)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";", lineterminator="\r\n")
        w.writerow(FIELDS)
        w.writerows([_cell(v) for v in asdict(r).values()] for r in rows)
    return path


def write_json(rows: list[InventoryRow], path: Path, source: Path | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source": str(source) if source else None,
        "generated": datetime.now().isoformat(timespec="seconds"),
        "length_scaled_note": f"length_scaled = length_px × Scale.Value {SCALE_FLAG}",
        "rows": [asdict(r) for r in rows],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path
