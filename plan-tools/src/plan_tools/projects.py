"""Localisation d'un projet « S-xxxx » dans le dossier OneDrive « Mes projets »."""

from __future__ import annotations

import os
import re
from pathlib import Path

# Path.home() = %USERPROFILE% sous Windows : aucun nom de compte en dur.
DEFAULT_ROOT = (
    Path.home() / "OneDrive - GROUPE DR ELECTRIQUE INC" / "DANIEL-FRANCIS-JO" / "Mes projets"
)
ENV_ROOT = "PLAN_TOOLS_PROJECTS_ROOT"


class ProjectError(LookupError):
    """Projet introuvable ou ambigu (message en français, destiné à Jo)."""


def projects_root() -> Path:
    return Path(os.environ.get(ENV_ROOT) or DEFAULT_ROOT)


def _qpl_files(folder: Path) -> list[Path]:
    """Les .qpl du dossier, en excluant les copies « * - IA.qpl »."""
    return [
        p for p in folder.glob("*.qpl") if p.is_file() and not p.name.lower().endswith(" - ia.qpl")
    ]


def newest_qpl(folder: Path) -> Path:
    """Le .qpl le plus récent du dossier (hors copies « * - IA.qpl »)."""
    candidates = _qpl_files(folder)
    if not candidates:
        raise ProjectError(f"Aucun fichier .qpl dans « {folder} ».")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def find_project(code: str, root: Path | None = None) -> tuple[Path, list[Path]]:
    """(.qpl, autres dossiers) du projet dont le dossier commence par `code` (ex. « S-1849 »),
    suivi d'une espace, de « ( », « _ », « . », « - » ou de la fin du nom.

    Plusieurs dossiers : on prend celui dont le .qpl le plus récent est le plus récent ; les
    autres sont renvoyés (du plus récent au plus ancien) pour que la CLI les signale.
    """
    base = root or projects_root()
    if not base.is_dir():
        raise ProjectError(f"Dossier des projets introuvable : « {base} » (variable {ENV_ROOT}).")
    pattern = re.compile(rf"^{re.escape(code.strip())}(?=[\s(_.\-]|$)", re.IGNORECASE)
    matches = sorted(d for d in base.iterdir() if d.is_dir() and pattern.match(d.name))
    if not matches:
        raise ProjectError(f"Aucun dossier de projet ne correspond à « {code} » dans « {base} ».")
    matches.sort(  # tri stable : à date égale, ordre alphabétique ; dossiers sans .qpl à la fin
        key=lambda d: max((p.stat().st_mtime for p in _qpl_files(d)), default=-1.0), reverse=True
    )
    return newest_qpl(matches[0]), matches[1:]


def resolve_target(target: str, root: Path | None = None) -> tuple[Path, list[Path]]:
    """Accepte un code projet, un chemin vers un .qpl ou un dossier de projet.

    Renvoie (.qpl, autres dossiers correspondant au code) ; liste vide pour un chemin.
    """
    p = Path(target)
    if p.is_file():
        return p, []
    if p.is_dir():
        return newest_qpl(p), []
    return find_project(target, root)
