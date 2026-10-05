"""Embeddings Ollama (même appel que email-vectorizer : POST /api/embed, lots de 32)."""

from __future__ import annotations

import httpx

from .config import BATCH_SIZE, MODEL_NAME, OLLAMA_URL, VECTOR_SIZE


class OllamaEmbedder:
    def __init__(
        self,
        url: str = OLLAMA_URL,
        model: str = MODEL_NAME,
        batch_size: int = BATCH_SIZE,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.url = url
        self.model = model
        self.batch_size = batch_size
        self._http = httpx.Client(base_url=url, timeout=300, transport=transport)

    def check(self) -> None:
        """Vérifie qu'Ollama répond et que le modèle est installé (RuntimeError sinon)."""
        try:
            resp = self._http.get("/api/tags", timeout=5)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise RuntimeError(
                f"Ollama injoignable à {self.url} ({exc}). Démarrer Ollama : ollama serve"
            ) from exc
        models = [m.get("name", "") for m in resp.json().get("models", [])]
        if not any(self.model in m for m in models):
            raise RuntimeError(
                f"Modèle '{self.model}' absent d'Ollama. Installer : ollama pull {self.model}\n"
                f"Disponibles : {models}"
            )

    def embed(self, texts: list[str]) -> list[list[float]]:
        """Vecteurs (4096 dims) pour `texts`, envoyés par lots de `batch_size`."""
        vectors: list[list[float]] = []
        for i in range(0, len(texts), self.batch_size):
            batch = texts[i : i + self.batch_size]
            try:
                resp = self._http.post("/api/embed", json={"model": self.model, "input": batch})
                resp.raise_for_status()
            except httpx.HTTPError as exc:
                raise RuntimeError(f"Échec de l'embedding Ollama ({exc})") from exc
            embs = resp.json().get("embeddings") or []
            if len(embs) != len(batch) or any(len(v) != VECTOR_SIZE for v in embs):
                raise RuntimeError(
                    f"Réponse Ollama inattendue : {len(embs)} vecteur(s) pour {len(batch)} "
                    f"texte(s), {VECTOR_SIZE} dimensions attendues."
                )
            vectors.extend(embs)
        return vectors
