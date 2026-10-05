"""Test de bout en bout contre le vrai Qdrant + Ollama ; sauté s'ils ne répondent pas."""

import httpx
import pytest
from typer.testing import CliRunner

from code_rag import cli, store
from code_rag.config import MODEL_NAME, OLLAMA_URL, QDRANT_URL

COLLECTION = "codes_electriques_test"


def _services_up() -> bool:
    try:
        httpx.get(f"{QDRANT_URL}/healthz", timeout=2).raise_for_status()
        tags = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=2).json()
    except (httpx.HTTPError, ValueError):
        return False
    return any(MODEL_NAME in m.get("name", "") for m in tags.get("models", []))


@pytest.mark.integration
@pytest.mark.skipif(not _services_up(), reason="Qdrant ou Ollama (qwen3-embedding:8b) absent")
def test_ingest_and_ask_live(tiny_pdf):
    runner = CliRunner()
    client = store.connect()
    try:
        ingest = runner.invoke(cli.app, ["ingest", str(tiny_pdf), "--collection", COLLECTION])
        assert ingest.exit_code == 0, ingest.output

        ask = runner.invoke(
            cli.app,
            ["ask", "remplissage maximal des conduits", "--k", "1", "--collection", COLLECTION],
        )
        assert ask.exit_code == 0, ask.output
        assert "**[Mini Code p.1 — 12-3000]**" in ask.output
        assert ask.output.rstrip().endswith(cli.FINAL_LINE)
    finally:
        if client.collection_exists(COLLECTION):
            client.delete_collection(COLLECTION)
