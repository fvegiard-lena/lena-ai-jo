"""Accès Qdrant : collection, déduplication par ID, upsert, recherche, comptes par source."""

from __future__ import annotations

from datetime import UTC, datetime

from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PayloadSchemaType,
    PointStruct,
    VectorParams,
)

from .config import QDRANT_URL, VECTOR_SIZE
from .pdf import Chunk


def connect(url: str = QDRANT_URL) -> QdrantClient:
    return QdrantClient(url=url, timeout=30)


def ensure_collection(client: QdrantClient, name: str) -> None:
    """Crée la collection (4096 dims, cosinus) si absente ; refuse une dimension différente."""
    if client.collection_exists(name):
        size = client.get_collection(name).config.params.vectors.size
        if size != VECTOR_SIZE:
            raise RuntimeError(
                f"La collection '{name}' a des vecteurs de {size} dimensions "
                f"({VECTOR_SIZE} attendues). Choisir un autre --collection."
            )
        return
    client.create_collection(
        collection_name=name,
        vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
    )
    # Index sur `source` : filtre `ask --source` et comptes par source (`status`).
    client.create_payload_index(name, "source", PayloadSchemaType.KEYWORD)


def existing_ids(client: QdrantClient, name: str, ids: list[str]) -> set[str]:
    if not ids:
        return set()
    records = client.retrieve(name, ids=ids, with_payload=False, with_vectors=False)
    return {str(r.id) for r in records}


def upsert(
    client: QdrantClient, name: str, chunks: list[Chunk], vectors: list[list[float]]
) -> None:
    now = datetime.now(UTC).isoformat(timespec="seconds")
    points = [
        PointStruct(
            id=c.point_id,
            vector=v,
            payload={
                "source": c.source,
                "page": c.page,
                "chunk_index": c.chunk_index,
                "text": c.text,
                "article_hint": c.article_hint,
                "ingested_at": now,
            },
        )
        for c, v in zip(chunks, vectors, strict=True)
    ]
    client.upsert(collection_name=name, points=points)


def search(
    client: QdrantClient, name: str, vector: list[float], k: int, source: str | None = None
) -> list[dict]:
    query_filter = (
        Filter(must=[FieldCondition(key="source", match=MatchValue(value=source))])
        if source
        else None
    )
    res = client.query_points(
        collection_name=name, query=vector, query_filter=query_filter, limit=k, with_payload=True
    )
    return [p.payload or {} for p in res.points]


def counts_by_source(client: QdrantClient, name: str) -> dict[str, int]:
    res = client.facet(name, key="source", limit=1000, exact=True)
    return {str(hit.value): hit.count for hit in res.hits}
