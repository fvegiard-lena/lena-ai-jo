"""Réglages (surchargeables par variables d'environnement)."""

from __future__ import annotations

import os

QDRANT_URL = os.environ.get("CODE_RAG_QDRANT_URL", "http://localhost:6333")
OLLAMA_URL = os.environ.get("CODE_RAG_OLLAMA_URL", "http://localhost:11434")
COLLECTION = "codes_electriques"
MODEL_NAME = "qwen3-embedding:8b"
VECTOR_SIZE = 4096
BATCH_SIZE = 32  # comme email-vectorizer : lots Ollama, à ajuster selon la VRAM

CHUNK_CHARS = 3200  # ≈ 800 jetons
CHUNK_OVERLAP = 0.15
