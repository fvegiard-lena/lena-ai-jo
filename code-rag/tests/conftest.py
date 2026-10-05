"""Doublures communes : PDF minuscule, embedder Ollama simulé (MockTransport), faux Qdrant."""

from __future__ import annotations

import json
import random
import zlib
from pathlib import Path
from types import SimpleNamespace

import httpx
import pymupdf
import pytest

from code_rag.config import VECTOR_SIZE
from code_rag.embed import OllamaEmbedder

PAGE1 = "12-3000 Remplissage des conduits\nLe remplissage maximal des conduits est de 40 %."
PAGE2_HEAD = "Section 4 Labor units\nTable 2 Conduit installation hours per 100 feet\n"


def page2_text() -> str:
    lines = [f"Line {i:03d} EMT conduit labor unit value {i * 0.25:.2f} hours" for i in range(120)]
    return PAGE2_HEAD + "\n".join(lines)


def make_tiny_pdf(path: Path) -> Path:
    """3 pages : règle CSA courte, page longue (plusieurs extraits), page vide."""
    doc = pymupdf.open()
    doc.new_page().insert_text((50, 72), PAGE1, fontsize=10)
    doc.new_page(width=1200, height=2400).insert_text((40, 40), page2_text(), fontsize=8)
    doc.new_page()
    doc.save(path)
    doc.close()
    return path


def make_text_pdf(path: Path, lines: list[str], pages: int = 3) -> Path:
    """PDF dont chaque page porte les mêmes lignes de texte."""
    doc = pymupdf.open()
    for _ in range(pages):
        doc.new_page(width=1200, height=2400).insert_text((40, 40), "\n".join(lines), fontsize=8)
    doc.save(path)
    doc.close()
    return path


def french_lines() -> list[str]:
    """Vraies phrases françaises (> 500 caractères par page)."""
    return [
        f"Article {i} : le conduit doit être installé avec un câble dans le tableau."
        for i in range(12)
    ]


def salad_lines() -> list[str]:
    """Bruit façon couche texte factice : mots inventés de 5 à 10 lettres, sans mot réel."""
    rng = random.Random(42)
    letters = "abcdefghijklmnopqrstuvwxyz"
    return [
        " ".join("".join(rng.choices(letters, k=rng.randint(5, 10))) for _ in range(12))
        for _ in range(12)
    ]


@pytest.fixture
def tiny_pdf(tmp_path: Path) -> Path:
    return make_tiny_pdf(tmp_path / "Mini Code.pdf")


@pytest.fixture
def french_pdf(tmp_path: Path) -> Path:
    return make_text_pdf(tmp_path / "Francais.pdf", french_lines())


@pytest.fixture
def decoy_pdf(tmp_path: Path) -> Path:
    return make_text_pdf(tmp_path / "Factice.pdf", salad_lines())


def bag_of_words(text: str) -> list[float]:
    """Vecteur déterministe : sac de mots haché sur 4096 dimensions."""
    vec = [0.0] * VECTOR_SIZE
    for word in text.lower().split():
        vec[zlib.crc32(word.encode()) % VECTOR_SIZE] += 1.0
    return vec


class OllamaStub:
    """Faux serveur Ollama pour httpx.MockTransport ; mémorise les lots reçus."""

    def __init__(self, models: list[str] | None = None) -> None:
        self.models = models if models is not None else ["qwen3-embedding:8b"]
        self.batches: list[list[str]] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/tags":
            return httpx.Response(200, json={"models": [{"name": m} for m in self.models]})
        if request.url.path == "/api/embed":
            texts = json.loads(request.content)["input"]
            self.batches.append(texts)
            return httpx.Response(200, json={"embeddings": [bag_of_words(t) for t in texts]})
        return httpx.Response(404)


@pytest.fixture
def ollama() -> OllamaStub:
    return OllamaStub()


@pytest.fixture
def embedder(ollama: OllamaStub) -> OllamaEmbedder:
    return OllamaEmbedder(transport=httpx.MockTransport(ollama))


class FakeQdrant:
    """Sous-ensemble en mémoire de QdrantClient utilisé par code_rag.store."""

    def __init__(self) -> None:
        self.collections: dict[str, dict] = {}
        self.indexes: list[tuple[str, str]] = []

    def collection_exists(self, name: str) -> bool:
        return name in self.collections

    def create_collection(self, collection_name: str, vectors_config) -> None:
        self.collections[collection_name] = {"size": vectors_config.size, "points": {}}

    def get_collection(self, name: str):
        vectors = SimpleNamespace(size=self.collections[name]["size"])
        return SimpleNamespace(config=SimpleNamespace(params=SimpleNamespace(vectors=vectors)))

    def create_payload_index(self, name: str, field: str, schema) -> None:
        self.indexes.append((name, field))

    def retrieve(self, name: str, ids, with_payload=True, with_vectors=False):
        points = self.collections[name]["points"]
        return [SimpleNamespace(id=i) for i in ids if i in points]

    def upsert(self, collection_name: str, points) -> None:
        for p in points:
            self.collections[collection_name]["points"][p.id] = p

    def query_points(self, collection_name, query, query_filter=None, limit=10, with_payload=True):
        points = list(self.collections[collection_name]["points"].values())
        if query_filter is not None:
            cond = query_filter.must[0]
            points = [p for p in points if p.payload.get(cond.key) == cond.match.value]

        def score(p) -> float:
            return sum(a * b for a, b in zip(query, p.vector, strict=True))

        ranked = sorted(points, key=score, reverse=True)[:limit]
        hits = [SimpleNamespace(payload=p.payload, score=score(p)) for p in ranked]
        return SimpleNamespace(points=hits)

    def count(self, name: str, exact: bool = True):
        return SimpleNamespace(count=len(self.collections[name]["points"]))

    def facet(self, name: str, key: str, limit: int = 10, exact: bool = False):
        counts: dict[str, int] = {}
        for p in self.collections[name]["points"].values():
            counts[p.payload[key]] = counts.get(p.payload[key], 0) + 1
        return SimpleNamespace(hits=[SimpleNamespace(value=v, count=c) for v, c in counts.items()])


@pytest.fixture
def fake_qdrant() -> FakeQdrant:
    return FakeQdrant()
