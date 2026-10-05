"""Interface en ligne de commande `plan-tools` (typer)."""

from __future__ import annotations

import os
import re
import sys
import time
import tomllib
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Annotated

import typer
from lxml import etree

from .bom import BOM_KINDS, write_bom_csv
from .classify import ROLES, Config, classify_report, load_config
from .inventory import build_inventory, fmt_num, write_csv, write_json
from .layer_writer import conduit_group_id, ia_path, write_ia_qpl
from .model import LENGTH_KINDS, plans
from .overlay import overlay_path, plan_image, render_overlay, write_report
from .projects import ProjectError, find_project, resolve_target
from .qpl_io import QplDoc, load, roundtrip_check
from .route import NO_PANEL, route_doc

app = typer.Typer(
    no_args_is_help=True,
    add_completion=False,
    help="Outils Plan Expert (.qpl) : inventaire, bordereau (BOM), vérification aller-retour, "
    "tracé IA des conduits.",
)

TargetArg = Annotated[str, typer.Argument(help="Code projet (ex. S-0723), chemin .qpl ou dossier.")]
OutOpt = Annotated[
    str | None,
    typer.Option(
        "--out",
        help="Dossier de sortie. « IA » = dossier IA/ à côté du .qpl. "
        "Par défaut : %LOCALAPPDATA%\\plan-tools\\out\\<projet>\\ (jamais OneDrive).",
    ),
]


@app.callback()
def _main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def _fail(message: str) -> typer.Exit:
    typer.echo(f"Erreur : {message}", err=True)
    return typer.Exit(2)


def _picked(qpl: Path, others: list[Path]) -> None:
    """Plusieurs dossiers pour le même code : dire lequel a été pris (sur stderr)."""
    if others:
        typer.echo(
            f"Plusieurs dossiers trouvés, j'ai pris : {qpl.parent.name} "
            f"(autres : {', '.join(d.name for d in others)})",
            err=True,
        )


@contextmanager
def _writing() -> Iterator[None]:
    """Fichier de sortie ouvert ailleurs (Excel, Plan Expert…) : message clair, pas de trace."""
    try:
        yield
    except OSError as exc:
        name = f"« {exc.filename} »" if exc.filename else "le fichier de sortie"
        raise _fail(
            f"Impossible d'écrire {name} : ferme-le (Excel / Plan Expert) puis relance."
        ) from exc


def _open(target: str) -> tuple[Path, QplDoc]:
    try:
        qpl, others = resolve_target(target)
        _picked(qpl, others)
        return qpl, load(qpl)
    except ProjectError as exc:
        raise _fail(str(exc)) from exc
    except (OSError, etree.XMLSyntaxError) as exc:
        raise _fail(f"fichier .qpl illisible ({exc})") from exc


def _config() -> Config:
    try:
        return load_config()
    except (OSError, KeyError, ValueError, re.error, tomllib.TOMLDecodeError) as exc:
        raise _fail(f"config.toml illisible ({type(exc).__name__}: {exc})") from exc


def out_dir(qpl: Path, out: str | None) -> Path:
    if out is None:
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
        return base / "plan-tools" / "out" / qpl.stem
    if out.strip().upper() == "IA":
        return qpl.parent / "IA"
    return Path(out)


@app.command()
def inventory(target: TargetArg, out: OutOpt = None) -> None:
    """Inventaire par plan / calque / objet -> CSV (Excel FR) + JSON."""
    qpl, doc = _open(target)
    rows = build_inventory(doc)
    d = out_dir(qpl, out)
    with _writing():
        csv_path = write_csv(rows, d / f"{qpl.stem}.inventaire.csv")
        json_path = write_json(rows, d / f"{qpl.stem}.inventaire.json", source=qpl)
    all_plans = plans(doc.root)
    unscaled = sum(1 for p in all_plans if p.scale_value <= 0)
    counters = [r for r in rows if r.kind == "Counter"]
    length_px = sum(r.length_px for r in rows if r.kind in ("Line", "Perimeter"))
    typer.echo(f"Source : {qpl}")
    typer.echo(
        f"Plans : {len(all_plans)} (sans échelle : {unscaled} [À CONFIRMER — Jo]) ; "
        f"objets : {len(rows)}"
    )
    typer.echo(
        f"Symboles (Counter) : {sum(r.count for r in counters)} répartis sur "
        f"{len({r.name for r in counters})} types ; longueurs (Line/Perimeter) : "
        f"{length_px:.0f} px ; surfaces : {sum(1 for r in rows if r.kind == 'Area')}"
    )
    typer.echo(f"CSV : {csv_path}")
    typer.echo(f"JSON : {json_path}")


@app.command()
def bom(target: TargetArg, out: OutOpt = None) -> None:
    """Bordereau 13 colonnes (format Francis) -> CSV « ; » UTF-8 BOM."""
    qpl, doc = _open(target)
    rows = build_inventory(doc)
    with _writing():
        path = write_bom_csv(rows, out_dir(qpl, out) / f"{qpl.stem}.bom.csv")
    n = sum(1 for r in rows if r.kind in BOM_KINDS)
    n_len = sum(1 for r in rows if r.kind in LENGTH_KINDS)
    typer.echo(f"Source : {qpl}")
    typer.echo(
        f"Lignes BOM : {n} (dont {n_len} longueurs en px, statut « À valider ») ; "
        "Discipline / Modèle / Correction laissés vides"
    )
    typer.echo(f"CSV : {path}")


@app.command("roundtrip-check")
def roundtrip_check_cmd(
    path: Annotated[Path | None, typer.Argument(help="Fichier .qpl à vérifier.")] = None,
    all_root: Annotated[
        Path | None, typer.Option("--all", help="Vérifier tous les .qpl sous ce dossier.")
    ] = None,
) -> None:
    """Vérifie que la relecture/réécriture reproduit le fichier à l'octet près."""
    if all_root is not None:
        files = sorted(all_root.rglob("*.qpl"))
    elif path is not None:
        files = [path]
    else:
        raise _fail("indiquez un fichier .qpl ou --all <dossier>.")
    if not files:
        raise _fail("aucun fichier .qpl trouvé.")
    n_byte = n_c14n = 0
    for f in files:
        r = roundtrip_check(f)
        n_byte += r.byte_equal
        n_c14n += r.c14n_equal
        status = "OK" if r.byte_equal else ("C14N-SEUL" if r.c14n_equal else "ÉCHEC")
        typer.echo(f"{status}\t{f}")
        if r.error or r.diff_hint:
            typer.echo(f"\t{r.error or r.diff_hint}")
    n = len(files)
    typer.echo(
        f"Résumé : {n} fichier(s) ; identiques à l'octet : {n_byte} ({n_byte / n:.1%}) ; "
        f"C14N égaux : {n_c14n} ({n_c14n / n:.1%})"
    )
    if n_byte < n:
        raise typer.Exit(1)


@app.command("find-project")
def find_project_cmd(code: Annotated[str, typer.Argument(help="Code projet, ex. S-1849.")]) -> None:
    """Affiche le chemin du .qpl le plus récent du projet."""
    try:
        qpl, others = find_project(code)
    except ProjectError as exc:
        raise _fail(str(exc)) from exc
    _picked(qpl, others)
    typer.echo(str(qpl))


@app.command()
def route(
    target: TargetArg,
    out: OutOpt = None,
    plan: Annotated[
        str | None,
        typer.Option("--plan", help="Ne tracer que les plans dont le nom contient ce texte."),
    ] = None,
    wall_aware: Annotated[
        bool, typer.Option("--wall-aware", help="Contourner les murs (non implémenté en v1).")
    ] = False,
    force: Annotated[
        bool, typer.Option("--force", help="Remplacer les fichiers de sortie existants.")
    ] = False,
) -> None:
    """Trace les conduits IA (panneau -> appareils) : « - IA.qpl », aperçus PNG, rapport.md."""
    t0 = time.perf_counter()
    qpl, doc = _open(target)
    cfg = _config()
    try:
        routes = route_doc(doc, cfg, plan_filter=plan, wall_aware=wall_aware)
    except NotImplementedError as exc:
        raise _fail(str(exc)) from exc
    routed = [r for r in routes if r.runs]
    if plan and not routes:
        raise _fail(f"Aucun symbole à router sur « {plan} » : aucun plan ne correspond.")
    if plan and not routed:
        names = " ; ".join(f"« {r.name} »" for r in routes)
        raise _fail(
            f"Aucun symbole à router sur « {plan} » : {names} sans appareil à relier, "
            "aucun fichier écrit."
        )
    d = out_dir(qpl, out)
    ia = ia_path(qpl, d) if any(run.segments for r in routed for run in r.runs) else None
    images = {r.index: plan_image(qpl, r) for r in routed}
    pngs: dict[int, Path] = {}
    for r in routed:
        if images[r.index] is not None:
            p = overlay_path(d, r.name)  # noms de plan en double : suffixe = position du plan
            pngs[r.index] = overlay_path(d, f"{r.name} ({r.index})") if p in pngs.values() else p
    report = d / "rapport.md"
    targets = [p for p in (ia, report, *pngs.values()) if p is not None]
    existing = [p for p in targets if p.exists()]
    if existing and not force:
        raise _fail(
            f"« {existing[0]} » existe déjà ({len(existing)} fichier(s) de sortie) : "
            "relancer avec --force pour les remplacer."
        )
    with _writing():
        if ia is not None:
            try:
                write_ia_qpl(doc, routes, ia, cfg, force=force)
            except (FileExistsError, ValueError) as exc:
                raise _fail(str(exc)) from exc
        for r in routed:
            image = images[r.index]
            if image is None:
                typer.echo(
                    f"Avertissement : image introuvable pour « {r.name} » ({r.filename}) — "
                    "aperçu non généré.",
                    err=True,
                )
                continue
            render_overlay(image, r, pngs[r.index])
        write_report(report, qpl, ia, routes, pngs, conduit_group_id(doc.root, cfg))
    n_runs = sum(len(r.runs) for r in routed)
    n_dev = sum(r.n_devices for r in routed)
    no_panel = sum(1 for r in routed if any(f.startswith(NO_PANEL) for f in r.flags))
    elapsed = fmt_num(round(time.perf_counter() - t0, 1))
    typer.echo(
        f"Plans tracés : {len(routed)}/{len(routes)} ; parcours : {n_runs} ; "
        f"appareils reliés : {n_dev} ; durée : {elapsed} s (original non modifié : {qpl.name})"
    )
    typer.echo(
        f"Longueur IA : {fmt_num(round(sum(r.length_px for r in routed)))} px ; "
        f"[À CONFIRMER — Jo] : {no_panel} plan(s) sans panneau détecté, rôles des symboles "
        "(config.toml)"
    )
    typer.echo(
        f"Résultat : {ia or 'aucun (rien à tracer)'} ; rapport : {report} ; "
        f"aperçus PNG : {len(pngs)}"
    )


@app.command("classify-report")
def classify_report_cmd(target: TargetArg) -> None:
    """Rôle attribué à chaque nom de symbole (Counter), pour validation par Jo."""
    qpl, doc = _open(target)
    rows = classify_report(doc.root, _config())
    typer.echo(f"Source : {qpl}")
    typer.echo(f"{'Rôle':<7} {'Symboles':>8} {'Objets':>6}  {'Étiquette':<9}  Nom")
    for r in rows:
        typer.echo(f"{r.role:<7} {r.symbols:>8} {r.items:>6}  {r.tag or '':<9}  {r.name}")
    totals = " ; ".join(
        f"{role} : {sum(1 for r in rows if r.role == role)} noms / "
        f"{sum(r.symbols for r in rows if r.role == role)} symboles"
        for role in ROLES
    )
    typer.echo(f"Total — {totals}")
    typer.echo("Rôles [À CONFIRMER — Jo] : règles dans config.toml ([classify], [circuit]).")
