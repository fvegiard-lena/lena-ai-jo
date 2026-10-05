import httpx
import pytest

from code_rag.embed import OllamaEmbedder

from .conftest import OllamaStub


def test_embed_batches_of_32(embedder, ollama):
    vectors = embedder.embed([f"texte {i}" for i in range(70)])
    assert len(vectors) == 70
    assert all(len(v) == 4096 for v in vectors)
    assert [len(b) for b in ollama.batches] == [32, 32, 6]


def test_check_ok(embedder):
    embedder.check()


def test_check_missing_model():
    stub = OllamaStub(models=["gemma4:latest"])
    with pytest.raises(RuntimeError, match="ollama pull qwen3-embedding:8b"):
        OllamaEmbedder(transport=httpx.MockTransport(stub)).check()


def test_check_unreachable():
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refusé", request=request)

    with pytest.raises(RuntimeError, match="injoignable"):
        OllamaEmbedder(transport=httpx.MockTransport(refuse)).check()


def test_embed_http_error():
    def boom(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, json={"error": "out of memory"})

    with pytest.raises(RuntimeError, match="Échec de l'embedding"):
        OllamaEmbedder(transport=httpx.MockTransport(boom)).embed(["x"])


def test_embed_wrong_dimensions():
    def small(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"embeddings": [[0.1, 0.2]]})

    with pytest.raises(RuntimeError, match="4096 dimensions"):
        OllamaEmbedder(transport=httpx.MockTransport(small)).embed(["x"])
