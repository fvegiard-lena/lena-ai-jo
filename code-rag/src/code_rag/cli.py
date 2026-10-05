"""Interface en ligne de commande `code-rag` (typer) : ingest, ask, status."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Annotated

import httpx
import typer
from qdrant_client import QdrantClient

from . import store
from .config import COLLECTION, MODEL_NAME, OLLAMA_URL, QDRANT_URL
from .embed import OllamaEmbedder
from .pdf import Chunk, iter_pages, page_chunks

FINAL_LINE = (
    "Réponse à rédiger par Léna à partir des extraits ci-dessus ; "
    "si aucun extrait ne répond : [À CONFIRMER — Jo]"
)

app = typer.Typer(
    no_args_is_help=True,
    add_completion=False,
    help="Extraits cités des codes électriques (CSA, NECA, National Estimator) "
    "via Ollama + Qdrant.",
)

CollectionOpt = Annotated[str, typer.Option("--collection", help="Collection Qdrant.")]


# Fabriques remplacées par des doublures dans les tests.
def make_client() -> QdrantClient:
    return store.connect()


def make_embedder() -> OllamaEmbedder:
    return OllamaEmbedder()


def qdrant_health() -> None:
    try:
        httpx.get(f"{QDRANT_URL}/healthz", timeout=5).raise_for_status()
    except httpx.HTTPError as exc:
        raise RuntimeError(f"Qdrant injoignable à {QDRANT_URL} ({exc})") from exc


@app.callback()
def _main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def _fail(message: str) -> typer.Exit:
    typer.echo(f"Erreur : {message}", err=True)
    return typer.Exit(2)


def _collection_exists(client: QdrantClient, collection: str) -> bool:
    try:
        return client.collection_exists(collection)
    except Exception as exc:  # erreurs réseau du client Qdrant (types variables selon version)
        raise _fail(f"Qdrant injoignable à {QDRANT_URL} ({exc})") from exc


def _flush(
    client: QdrantClient, embedder: OllamaEmbedder, collection: str, pending: list[Chunk]
) -> None:
    if pending:
        store.upsert(client, collection, pending, embedder.embed([c.text for c in pending]))
        pending.clear()


def _ingest_pdf(
    client: QdrantClient,
    embedder: OllamaEmbedder,
    collection: str,
    pdf: Path,
    source: str,
    force: bool,
) -> None:
    pending: list[Chunk] = []
    added = skipped = empty = 0
    for page, total, text in iter_pages(pdf):
        chunks = page_chunks(source, page, text)
        if not chunks:
            empty += 1
        known = (
            set() if force else store.existing_ids(client, collection, [c.point_id for c in chunks])
        )
        new = [c for c in chunks if c.point_id not in known]
        added += len(new)
        skipped += len(chunks) - len(new)
        pending.extend(new)
        typer.echo(
            f"[{source}] p.{page}/{total} : {len(new)} extrait(s) à indexer, "
            f"{len(chunks) - len(new)} déjà présent(s)"
        )
        if len(pending) >= embedder.batch_size:
            _flush(client, embedder, collection, pending)
    _flush(client, embedder, collection, pending)
    typer.echo(
        f"[{source}] terminé : {added} extrait(s) indexé(s), {skipped} ignoré(s) (déjà présents)"
        + (f", {empty} page(s) sans texte (OCR nécessaire ?)" if empty else "")
    )


@app.command()
def ingest(
    pdfs: Annotated[
        list[Path],
        typer.Argument(help="PDF à indexer.", exists=True, dir_okay=False, readable=True),
    ],
    source: Annotated[
        str | None,
        typer.Option("--source", help="Nom de la source (défaut : nom du fichier sans .pdf)."),
    ] = None,
    collection: CollectionOpt = COLLECTION,
    force: Annotated[
        bool, typer.Option("--force", help="Ré-indexer même les extraits déjà présents.")
    ] = False,
) -> None:
    """Indexe des PDF page par page (reprise possible : les extraits présents sont sautés)."""
    if source and len(pdfs) > 1:
        raise _fail("--source ne s'utilise qu'avec un seul PDF.")
    embedder = make_embedder()
    try:
        embedder.check()
    except RuntimeError as exc:
        raise _fail(str(exc)) from exc
    client = make_client()
    _collection_exists(client, collection)
    try:
        store.ensure_collection(client, collection)
        for pdf in pdfs:
            _ingest_pdf(client, embedder, collection, pdf, source or pdf.stem, force)
    except RuntimeError as exc:
        raise _fail(
            f"{exc}\nRelancer la même commande : les extraits déjà indexés seront sautés."
        ) from exc


def format_hits(question: str, hits: list[dict], source: str | None) -> str:
    lines = [f"### Extraits pour : « {question} »", ""]
    if not hits:
        where = f"la source « {source} »" if source else "la collection"
        lines += [f"_Aucun extrait trouvé dans {where} (non ingérée ?)._", ""]
    for hit in hits:
        label = f"{hit.get('source', '?')} p.{hit.get('page', '?')}"
        if hit.get("article_hint"):
            label += f" — {hit['article_hint']}"
        lines += [f"**[{label}]** {hit.get('text', '').strip()}", ""]
    lines.append(FINAL_LINE)
    return "\n".join(lines)


@app.command()
def ask(
    question: Annotated[str, typer.Argument(help="Question en langage courant.")],
    k: Annotated[int, typer.Option("--k", min=1, help="Nombre d'extraits.")] = 6,
    source: Annotated[
        str | None, typer.Option("--source", help="Limiter à une source (ex. « CSA 2026 »).")
    ] = None,
    collection: CollectionOpt = COLLECTION,
) -> None:
    """Affiche les k extraits les plus proches (Markdown cité) ; ne rédige pas la réponse."""
    client = make_client()
    if not _collection_exists(client, collection):
        raise _fail(f"collection '{collection}' absente : aucun PDF ingéré (code-rag ingest).")
    try:
        vector = make_embedder().embed([question])[0]
    except RuntimeError as exc:
        raise _fail(str(exc)) from exc
    typer.echo(format_hits(question, store.search(client, collection, vector, k, source), source))


@app.command()
def status(collection: CollectionOpt = COLLECTION) -> None:
    """Joignabilité Qdrant / Ollama et nombre de points par source."""
    problems = 0
    try:
        qdrant_health()
        typer.echo(f"Qdrant : OK ({QDRANT_URL})")
        qdrant_ok = True
    except RuntimeError as exc:
        typer.echo(f"Qdrant : PROBLÈME — {exc}")
        qdrant_ok = False
        problems += 1
    try:
        make_embedder().check()
        typer.echo(f"Ollama : OK ({OLLAMA_URL}, modèle {MODEL_NAME})")
    except RuntimeError as exc:
        typer.echo(f"Ollama : PROBLÈME — {exc}")
        problems += 1
    if qdrant_ok:
        client = make_client()
        if not _collection_exists(client, collection):
            typer.echo(f"Collection '{collection}' : absente — 0 point (aucun PDF ingéré)")
        else:
            total = client.count(collection, exact=True).count
            typer.echo(f"Collection '{collection}' : {total} point(s)")
            for name, count in sorted(store.counts_by_source(client, collection).items()):
                typer.echo(f"  - {name} : {count} point(s)")
    if problems:
        raise typer.Exit(1)
