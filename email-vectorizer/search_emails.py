"""
Email Semantic Search
Query your vectorized emails with natural language via Ollama + Qdrant.

Usage:
  python search_emails.py "project proposal from last month"
  python search_emails.py "invoice payment overdue"
"""

import json
import sys
import urllib.request

from qdrant_client import QdrantClient

QDRANT_URL = "http://localhost:6333"
OLLAMA_URL = "http://localhost:11434"
COLLECTION_NAME = "emails"
MODEL_NAME = "qwen3-embedding:8b"
TOP_K = 10


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


def main():
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else input("Search query: ")
    if not query.strip():
        print("No query provided.")
        return

    print(f"Embedding query via Ollama ({MODEL_NAME})...")
    vec = ollama_embed(query)

    print(f"Searching for: '{query}'")
    client = QdrantClient(url=QDRANT_URL)

    response = client.query_points(
        collection_name=COLLECTION_NAME,
        query=vec,
        limit=TOP_K,
        with_payload=True,
    )
    results = response.points

    print(f"\nTop {len(results)} results:\n{'-'*60}")
    for i, r in enumerate(results, 1):
        p = r.payload
        print(f"[{i}] Score: {r.score:.4f}")
        print(f"    Subject : {p.get('subject', 'N/A')}")
        print(f"    From    : {p.get('sender', 'N/A')}")
        print(f"    Date    : {p.get('sent_on', 'N/A')}")
        print(f"    Folder  : {p.get('folder', 'N/A')}")
        print(f"    Preview : {p.get('body_preview', '')[:120]}...")
        print()


if __name__ == "__main__":
    main()
