"""Le serveur MCP email-search demarre en stdio (SDK officiel) et expose ses outils.

list_tools / email_stats marchent hors ligne (sans Qdrant ni Ollama) ;
le test de recherche est saute si Qdrant ou Ollama (qwen3-embedding:8b) manque.
"""

import json
import sys
import urllib.request
from pathlib import Path

import anyio
import pytest
from mcp import Client, StdioServerParameters

SERVER = Path(__file__).resolve().parents[1] / "email_search_mcp.py"
PARAMS = StdioServerParameters(command=sys.executable, args=[str(SERVER)])


def _get_json(url: str):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            return json.load(resp)
    except (OSError, ValueError):
        return None


def _search_backends_ready() -> bool:
    if _get_json("http://localhost:6333/collections/emails") is None:
        return False
    tags = _get_json("http://localhost:11434/api/tags") or {}
    return any(m.get("name") == "qwen3-embedding:8b" for m in tags.get("models", []))


async def _session(mode: str, call: tuple[str, dict] | None = None):
    async with Client(PARAMS, mode=mode, read_timeout_seconds=120) as client:
        tools = (await client.list_tools()).tools
        result = await client.call_tool(*call) if call else None
        return tools, result


# "legacy" = poignee de main initialize d'avant 2026, comme Claude Desktop.
@pytest.mark.parametrize("mode", ["auto", "legacy"])
def test_list_tools_offline(mode):
    tools, _ = anyio.run(_session, mode)
    by_name = {t.name: t for t in tools}
    assert set(by_name) == {"search_emails", "email_stats"}

    schema = by_name["search_emails"].input_schema
    assert schema["required"] == ["query"]
    assert schema["properties"]["query"]["type"] == "string"
    assert schema["properties"]["limit"]["type"] == "integer"
    assert schema["properties"]["limit"]["default"] == 10
    assert by_name["email_stats"].input_schema.get("properties", {}) == {}


def test_email_stats_answers_without_backends():
    _, result = anyio.run(_session, "legacy", ("email_stats", {}))
    assert not result.is_error
    stats = json.loads(result.content[0].text)
    assert "total_emails" in stats and "status" in stats


NO_BACKENDS = "Qdrant (collection emails) ou Ollama (qwen3-embedding:8b) absent"


@pytest.mark.skipif(not _search_backends_ready(), reason=NO_BACKENDS)
def test_search_emails_returns_json_list():
    _, result = anyio.run(_session, "legacy", ("search_emails", {"query": "facture", "limit": 3}))
    assert not result.is_error, result.content
    hits = json.loads(result.content[0].text)
    assert isinstance(hits, list) and len(hits) <= 3
