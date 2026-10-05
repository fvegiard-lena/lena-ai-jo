"""Phase C : aperçus PNG (tracés IA en magenta semi-transparent) et rapport.md en français."""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Mapping, Sequence
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw

from .inventory import fmt_num
from .layer_writer import LAYER_NAME, line_name
from .route import NO_PANEL, PlanRoute

# Les plans Plan Expert font 50 à 120 Mpx, au-delà du garde-fou « decompression bomb » de
# Pillow (~89 Mpx). Ce sont des fichiers locaux de confiance : on lève volontairement la limite.
Image.MAX_IMAGE_PIXELS = None

MAX_WIDTH = 4000
MAGENTA = (255, 0, 255, 150)
SCALE_FLAG = "[À CONFIRMER — Jo] unité d'échelle"
_BAD_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def overlay_path(out_dir: Path, plan_name: str) -> Path:
    safe = _BAD_CHARS.sub("_", plan_name).strip(" .") or "plan"
    return out_dir / f"{safe} - IA.png"


def plan_image(qpl: Path, route: PlanRoute) -> Path | None:
    """Image du plan (Plan/@FileName) dans le dossier du .qpl, ou None si absente."""
    if not route.filename:
        return None
    p = qpl.parent / Path(route.filename.replace("\\", "/")).name
    return p if p.is_file() else None


def render_overlay(png: Path, route: PlanRoute, dest: Path, max_width: int = MAX_WIDTH) -> Path:
    """Dessine les parcours sur l'image réduite à `max_width` px de large au plus."""
    with Image.open(png) as src:
        img = src.convert("RGB")
    full_width = img.width
    if img.width > max_width:
        img.thumbnail((max_width, img.height), Image.Resampling.LANCZOS)
    s = img.width / full_width
    pen = max(2, round(img.width / 800))
    half = max(2, pen)
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for run in route.runs:
        for x1, y1, x2, y2 in run.segments:
            draw.line([(x1 * s, y1 * s), (x2 * s, y2 * s)], fill=MAGENTA, width=pen)
        for d in run.devices:
            cx, cy = d.x * s, d.y * s
            draw.rectangle([cx - half, cy - half, cx + half, cy + half], fill=MAGENTA)
    r = 4 * pen
    for px, py in route.panels:
        draw.ellipse([px * s - r, py * s - r, px * s + r, py * s + r], outline=MAGENTA, width=pen)
    out = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
    dest.parent.mkdir(parents=True, exist_ok=True)
    out.save(dest, "PNG")
    return dest


def _md(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def _px(value: float) -> str:
    return fmt_num(round(value))


def _scaled(route: PlanRoute) -> str:
    if route.scale_value <= 0:
        return "[À CONFIRMER — Jo] échelle non définie"
    scaled = route.length_px * route.scale_value
    return f"× échelle {fmt_num(route.scale_value)} = {fmt_num(round(scaled, 1))} — {SCALE_FLAG}"


def _plan_flags(route: PlanRoute, image: Path | None) -> list[str]:
    flags = list(route.flags)
    if image is None:
        flags.append(f"[À CONFIRMER — Jo] image introuvable ({route.filename}) : pas d'aperçu")
    return flags


def write_report(
    dest: Path,
    qpl: Path,
    ia_qpl: Path | None,
    routes: Sequence[PlanRoute],
    overlays: Mapping[int, Path | None],
    group_id: int | None = None,
) -> Path:
    """rapport.md (FR) : bloc « Pour Jo », puis par plan tracé, parcours, appareils, longueurs
    et drapeaux. `group_id` : GroupID repris par les Line IA (conduit 3/4 du catalogue)."""
    routed = [r for r in routes if r.runs]
    empty = [r for r in routes if not r.runs]
    no_panel = sum(1 for r in routed if any(f.startswith(NO_PANEL) for f in r.flags))
    gid = f"GroupID {group_id}" if group_id is not None else "aucun GroupID (pas de conduit 3/4)"
    lines = [
        f"# Tracé IA des conduits — {qpl.stem}",
        "",
        "## Pour Jo",
        "",
        f"1. Original intact (jamais modifié) : `{qpl}`",
        (
            f"2. Résultat à ouvrir dans Plan Expert : `{ia_qpl.name}`"
            if ia_qpl
            else "2. Résultat : aucun fichier « - IA.qpl » (rien à tracer)"
        ),
        f"3. **[À CONFIRMER — Jo]** (a) détection des panneaux ({no_panel} plan(s) sans panneau "
        f"détecté ; règles `config.toml`) ; (b) Plan Expert accepte-t-il les Line "
        f"« {line_name('…')} » qui reprennent le {gid} ?",
        "",
        f"- Source : `{qpl}` — **non modifiée**",
        (
            f"- Résultat : `{ia_qpl}` (calque « {LAYER_NAME} », magenta) — à ouvrir dans "
            "Plan Expert pour validation **[À CONFIRMER — Jo]**"
            if ia_qpl
            else "- Résultat : aucun appareil à relier, pas de fichier « - IA.qpl »"
        ),
        f"- Généré le {datetime.now():%Y-%m-%d %H:%M}",
        "- Règles : `config.toml` — rôles des symboles (panneau / appareil / ignoré) et "
        "regroupement des circuits **[À CONFIRMER — Jo]**",
        "- Tracé géométrique en L (horizontal / vertical), sans tenir compte des murs ; "
        "longueurs en pixels de l'image du plan.",
        "",
        "## Résumé",
        "",
        "| Plan | Parcours | Appareils | Longueur (px) | Aperçu | Drapeaux |",
        "|---|---:|---:|---:|---|---|",
    ]
    for r in routed:
        png = overlays.get(r.index)
        n_flags = len(_plan_flags(r, png))
        lines.append(
            f"| {_md(r.name)} | {len(r.runs)} | {r.n_devices} | {_px(r.length_px)} | "
            f"{'oui' if png else 'non'} | {n_flags or ''} |"
        )
    total = sum(r.length_px for r in routed)
    n_dev = sum(r.n_devices for r in routed)
    n_runs = sum(len(r.runs) for r in routed)
    lines += [
        f"| **Total** | **{n_runs}** | **{n_dev}** | **{_px(total)}** | | |",
        "",
    ]
    if empty:
        lines += [
            f"Plans sans appareil à relier ({len(empty)}) : "
            + " ; ".join(_md(r.name) for r in empty),
            "",
        ]
    for r in routed:
        png = overlays.get(r.index)
        lines += [
            f"## {_md(r.name)}",
            "",
            f"- Image : `{r.filename}` — aperçu : " + (f"`{png}`" if png else "aucun"),
            f"- Panneaux détectés : {len(r.panels)} ; symboles ignorés (à enlever / existants) : "
            f"{r.n_ignored}",
            f"- Longueur totale : {_px(r.length_px)} px ({_scaled(r)})",
        ]
        lines += [f"- {_md(f)}" for f in _plan_flags(r, png)]
        lines += [
            "",
            "| # | Circuit | Départ | Appareils | Longueur (px) | Détail |",
            "|---:|---|---|---:|---:|---|",
        ]
        for i, run in enumerate(r.runs, 1):
            mix = Counter(d.name for d in run.devices)
            detail = ", ".join(f"{_md(n)} ×{k}" for n, k in sorted(mix.items()))
            if not run.segments:
                detail += " (appareil seul : aucun segment, pas de Line écrite)"
            start = "panneau" if run.from_panel else "appareil"
            lines.append(
                f"| {i} | {_md(run.tag)} | {start} | {len(run.devices)} | "
                f"{_px(run.length_px)} | {detail} |"
            )
        lines.append("")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(lines), encoding="utf-8")
    return dest
