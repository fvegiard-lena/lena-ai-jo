"""Bordereau (BOM) au format exact de Francis : 13 colonnes, séparateur « ; »."""

from __future__ import annotations

import csv
from pathlib import Path

from .inventory import InventoryRow, fmt_num
from .model import LENGTH_KINDS

HEADER = [
    "Plan",
    "Discipline",
    "Code Canonique DR",
    "Description Technique",
    "Modele / Reference Fabricant",
    "Localisation",
    "Qte Brute",
    "Correction / Regle Appliquee",
    "Qte Finale",
    "Unite",
    "Statut Action",
    "Notes Chantier",
    "Reference feuille",
]

# Seuls les objets quantifiables vont au bordereau ; Rectangle/Legend/Note/Angle = annotations.
BOM_KINDS = ("Counter", *LENGTH_KINDS)
STATUS = "À valider"
NO_SCALE = "[À CONFIRMER — Jo] échelle non définie"


def _notes(r: InventoryRow) -> str:
    if r.kind not in LENGTH_KINDS:
        return ""
    if r.scale_value > 0 and r.length_scaled is not None:
        notes = [
            f"Longueur × échelle ({fmt_num(r.scale_value)}) = {fmt_num(r.length_scaled)} "
            "[À CONFIRMER — Jo] unité d'échelle"
        ]
    else:
        notes = [NO_SCALE]
    if r.kind == "Area" and r.area_px2 is not None:
        notes.append(f"Surface = {fmt_num(r.area_px2)} px²")
    return " ; ".join(notes)


def bom_rows(rows: list[InventoryRow]) -> list[list[str]]:
    out = []
    for r in rows:
        if r.kind not in BOM_KINDS:
            continue
        qty = fmt_num(r.count if r.kind == "Counter" else r.length_px)
        out.append(
            [
                r.plan,
                "",
                r.key or r.name,
                r.description or r.name,
                "",
                r.layer,
                qty,
                "",
                qty,
                "un" if r.kind == "Counter" else "px",
                STATUS,
                _notes(r),
                r.filename,
            ]
        )
    return out


def write_bom_csv(rows: list[InventoryRow], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";", lineterminator="\r\n")
        w.writerow(HEADER)
        w.writerows(bom_rows(rows))
    return path
