"""
Email Search MCP Server
Exposes semantic email search to Claude Desktop via MCP (stdio), built on the
official MCP Python SDK (`mcp` 2.x: `MCPServer`, formerly `FastMCP` in 1.x).
Uses Ollama qwen3-embedding:8b (4096-dim) + Qdrant.

Add to claude_desktop_config.json (mettre le chemin reel, Claude Desktop ne
developpe pas %USERPROFILE%) :
  "email-search": {
    "command": "uv",
    "args": ["run", "--project", "<repo>/email-vectorizer",
             "python", "<repo>/email-vectorizer/email_search_mcp.py"]
  }
"""

import json
import urllib.request
from typing import Annotated

from mcp.server.mcpserver import MCPServer
from pydantic import Field
from qdrant_client import QdrantClient

QDRANT_URL = "http://localhost:6333"
OLLAMA_URL = "http://localhost:11434"
COLLECTION_NAME = "emails"
MODEL_NAME = "qwen3-embedding:8b"

mcp = MCPServer("email-search", version="2.0.0")

client = None


def get_client():
    global client
    if client is None:
        client = QdrantClient(url=QDRANT_URL)
    return client


def ollama_embed(text: str) -> list:
    data = json.dumps({"model": MODEL_NAME, "input": text}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.load(resp)
    return result["embeddings"][0]


def search_emails(query: str, limit: int = 10) -> list:
    vec = ollama_embed(query)
    response = get_client().query_points(
        collection_name=COLLECTION_NAME,
        query=vec,
        limit=limit,
        with_payload=True,
    )
    return [
        {
            "score": round(r.score, 4),
            "subject": r.payload.get("subject", ""),
            "sender": r.payload.get("sender", ""),
            "sent_on": r.payload.get("sent_on", ""),
            "folder": r.payload.get("folder", ""),
            "preview": r.payload.get("body_preview", "")[:200],
        }
        for r in response.points
    ]


def get_stats() -> dict:
    try:
        info = get_client().get_collection(COLLECTION_NAME)
        return {
            "total_emails": info.points_count,
            "model": MODEL_NAME,
            "vector_dims": 4096,
            "status": "ready",
        }
    except Exception as e:
        return {"total_emails": 0, "status": str(e)}


# --- Outils MCP (memes noms, arguments et sorties texte JSON qu'avant) ---------


@mcp.tool(
    name="search_emails",
    description=(
        "Semantic search through all vectorized emails using natural language. "
        "Uses Ollama qwen3-embedding:8b model."
    ),
    structured_output=False,
)
def search_emails_tool(
    query: Annotated[str, Field(description="Natural language search query")],
    limit: Annotated[int, Field(description="Number of results (default 10)")] = 10,
) -> str:
    return json.dumps(search_emails(query, limit), indent=2, ensure_ascii=False)


@mcp.tool(
    name="email_stats",
    description="Get statistics about the vectorized email database",
    structured_output=False,
)
def email_stats_tool() -> str:
    return json.dumps(get_stats(), indent=2)


def main():
    mcp.run()  # stdio par defaut


if __name__ == "__main__":
    main()
