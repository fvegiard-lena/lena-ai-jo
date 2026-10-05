"""
Email Vectorization Pipeline
Extracts emails from Outlook via COM, embeds with Ollama qwen3-embedding:8b, stores in Qdrant.

Requirements:
  uv add qdrant-client pywin32 tqdm

Usage:
  python vectorize_emails.py

Make sure Qdrant and Ollama are running before starting.
"""

import hashlib
import json
import sys
import urllib.request

import pythoncom
import win32com.client
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams
from tqdm import tqdm

# ── Configuration ──────────────────────────────────────────────────────────────

QDRANT_URL = "http://localhost:6333"
OLLAMA_URL = "http://localhost:11434"
COLLECTION_NAME = "emails"
MODEL_NAME = "qwen3-embedding:8b"
VECTOR_SIZE = 4096
BATCH_SIZE = 32        # Ollama processes batches; tune based on VRAM
MAX_TEXT_LEN = 1000    # Chars to keep per email body

# ── Ollama embedding ────────────────────────────────────────────────────────────

def ollama_embed(texts: list) -> list:
    """Embed a batch of texts using Ollama qwen3-embedding:8b. Returns list of vectors."""
    data = json.dumps({"model": MODEL_NAME, "input": texts}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        result = json.load(resp)
    return result["embeddings"]


def check_ollama():
    """Verify Ollama is running and model is available."""
    try:
        with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=5) as resp:
            tags = json.load(resp)
        models = [m["name"] for m in tags.get("models", [])]
        if not any(MODEL_NAME in m for m in models):
            raise RuntimeError(
                f"Model '{MODEL_NAME}' not found in Ollama.\n"
                f"Pull it with: ollama pull {MODEL_NAME}\n"
                f"Available: {models}"
            )
        print(f"  Ollama OK - model '{MODEL_NAME}' ready")
    except urllib.error.URLError:
        raise RuntimeError(
            f"Ollama not reachable at {OLLAMA_URL}.\n"
            "Start Ollama: ollama serve"
        ) from None


# ── Helpers ────────────────────────────────────────────────────────────────────

def email_id(subject: str, sent_on: str, sender: str) -> str:
    """Stable deterministic ID for deduplication."""
    raw = f"{subject}|{sent_on}|{sender}"
    return hashlib.sha256(raw.encode()).hexdigest()


def safe_str(value) -> str:
    try:
        return str(value) if value else ""
    except Exception:
        return ""


def extract_emails_from_folder(folder, emails: list, depth: int = 0):
    """Recursively extract emails from an Outlook folder tree."""
    try:
        items = folder.Items
        items.Sort("[ReceivedTime]", True)
        count = items.Count
        for i in range(1, count + 1):
            try:
                item = items[i]
                if item.Class == 43:  # olMail
                    subject = safe_str(item.Subject)
                    body = safe_str(item.Body)[:MAX_TEXT_LEN]
                    sender = safe_str(item.SenderEmailAddress)
                    recipients = safe_str(item.To)
                    try:
                        sent_on = str(item.SentOn)
                    except Exception:
                        sent_on = ""
                    emails.append({
                        "id": email_id(subject, sent_on, sender),
                        "subject": subject,
                        "body": body,
                        "sender": sender,
                        "recipients": recipients,
                        "sent_on": sent_on,
                        "folder": folder.FolderPath,
                    })
            except Exception:
                continue
    except Exception:
        pass

    try:
        for sub in folder.Folders:
            extract_emails_from_folder(sub, emails, depth + 1)
    except Exception:
        pass


def build_text(email: dict) -> str:
    parts = []
    if email["subject"]:
        parts.append(f"Subject: {email['subject']}")
    if email["sender"]:
        parts.append(f"From: {email['sender']}")
    if email["body"]:
        parts.append(email["body"])
    return "\n".join(parts)


# ── Main pipeline ──────────────────────────────────────────────────────────────

def main():
    print("=== Email Vectorization Pipeline ===")
    print(f"Model: {MODEL_NAME} (via Ollama) | Dims: {VECTOR_SIZE} | Batch: {BATCH_SIZE}")

    # 1. Check Ollama
    print("\n[1/5] Checking Ollama...")
    check_ollama()

    # 2. Connect to Qdrant
    print("\n[2/5] Connecting to Qdrant...")
    client = QdrantClient(url=QDRANT_URL, timeout=30)
    try:
        info = client.get_collection(COLLECTION_NAME)
        existing_size = info.config.params.vectors.size
        if existing_size != VECTOR_SIZE:
            print(
                f"  Collection has {existing_size}-dim vectors, "
                f"recreating for {VECTOR_SIZE}-dim..."
            )
            client.delete_collection(COLLECTION_NAME)
            raise Exception("recreate")
        print(f"  Collection '{COLLECTION_NAME}' exists ({info.points_count:,} vectors).")
    except Exception:
        print(f"  Creating collection '{COLLECTION_NAME}' ({VECTOR_SIZE} dims, cosine)...")
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
        )
        print("  Collection created.")

    # 3. Extract emails from Outlook
    print("\n[3/5] Connecting to Outlook and extracting emails...")
    print("  (This may take a few minutes for large mailboxes...)")
    pythoncom.CoInitialize()
    try:
        outlook = win32com.client.GetActiveObject("Outlook.Application")
    except Exception:
        outlook = win32com.client.Dispatch("Outlook.Application")
    namespace = outlook.GetNamespace("MAPI")

    all_emails = []
    for account in namespace.Accounts:
        print(f"  Account: {account.DisplayName}")
        try:
            inbox = namespace.Stores[account.DisplayName].GetRootFolder()
            extract_emails_from_folder(inbox, all_emails)
        except Exception as e:
            print(f"  Warning: Could not access {account.DisplayName}: {e}")

    if not all_emails:
        print("  No emails found. Is Outlook open and configured?")
        sys.exit(1)

    print(f"  Extracted {len(all_emails):,} emails total.")

    # 4. Embed via Ollama in batches
    print(f"\n[4/5] Embedding {len(all_emails):,} emails via Ollama ({MODEL_NAME})...")
    texts = [build_text(e) for e in all_emails]
    vectors = []

    for i in tqdm(range(0, len(texts), BATCH_SIZE), desc="Embedding"):
        batch = texts[i : i + BATCH_SIZE]
        embs = ollama_embed(batch)
        vectors.extend(embs)

    # 5. Upsert to Qdrant
    print(f"\n[5/5] Upserting {len(all_emails):,} vectors to Qdrant...")
    upsert_batch = 256
    for i in tqdm(range(0, len(all_emails), upsert_batch), desc="Upserting"):
        chunk_emails = all_emails[i : i + upsert_batch]
        chunk_vectors = vectors[i : i + upsert_batch]
        points = [
            PointStruct(
                id=int(email["id"][:8], 16),  # 32-bit uint from hash prefix
                vector=vec,
                payload={
                    "subject": email["subject"],
                    "sender": email["sender"],
                    "recipients": email["recipients"],
                    "sent_on": email["sent_on"],
                    "folder": email["folder"],
                    "body_preview": email["body"][:300],
                },
            )
            for email, vec in zip(chunk_emails, chunk_vectors, strict=False)
        ]
        client.upsert(collection_name=COLLECTION_NAME, points=points)

    info = client.get_collection(COLLECTION_NAME)
    print("\n=== Done! ===")
    print(f"Collection '{COLLECTION_NAME}': {info.points_count:,} vectors stored.")
    print("Qdrant dashboard: http://localhost:6333/dashboard")


if __name__ == "__main__":
    main()
