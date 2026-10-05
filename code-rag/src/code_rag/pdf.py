"""Extraction du texte PDF page par page, découpage en extraits et repérage d'articles."""

from __future__ import annotations

import re
import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from .config import CHUNK_CHARS, CHUNK_OVERLAP

# Numéro de règle CSA en début de ligne (ex. « 12-3000 »), sinon Section / Table / Tableau.
_RULE_RE = re.compile(r"^\s*(\d{1,2}-\d{3,4})\b", re.MULTILINE)
_HEADING_RE = re.compile(r"\b((?:Section|Table|Tableau)\s+\d+[A-Z]?(?:[-.]\d+)*)\b")


@dataclass(frozen=True)
class Chunk:
    source: str
    page: int  # 1-based
    chunk_index: int  # rang dans la page
    text: str
    article_hint: str

    @property
    def point_id(self) -> str:
        return point_id(self.source, self.page, self.chunk_index)


def point_id(source: str, page: int, chunk_index: int) -> str:
    """ID déterministe : ré-ingérer le même PDF écrase les mêmes points (idempotent)."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{source}|{page}|{chunk_index}"))


def article_hint(text: str) -> str:
    """Premier numéro d'article / section / table trouvé dans l'extrait, sinon ''."""
    for pattern in (_RULE_RE, _HEADING_RE):
        match = pattern.search(text)
        if match:
            return match.group(1)
    return ""


def chunk_text(text: str, size: int = CHUNK_CHARS, overlap: float = CHUNK_OVERLAP) -> list[str]:
    """Fenêtres d'environ `size` caractères, chevauchement `overlap`, coupées sur un espace."""
    text = text.strip()
    if not text:
        return []
    back = int(size * overlap)
    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        if end < len(text):
            cut = max(text.rfind(" ", end - back, end), text.rfind("\n", end - back, end))
            if cut > start:
                end = cut
        piece = text[start:end].strip()
        if piece:
            chunks.append(piece)
        if end >= len(text):
            break
        start = max(end - back, start + 1)
    return chunks


def iter_pages(pdf: Path) -> Iterator[tuple[int, int, str]]:
    """(numéro de page 1-based, nombre total de pages, texte) pour chaque page."""
    with pymupdf.open(pdf) as doc:
        total = doc.page_count
        for page in doc:
            yield page.number + 1, total, page.get_text()


def page_chunks(source: str, page: int, text: str) -> list[Chunk]:
    """Extraits d'une seule page : un extrait ne chevauche jamais deux pages."""
    return [
        Chunk(source, page, i, piece, article_hint(piece))
        for i, piece in enumerate(chunk_text(text))
    ]
