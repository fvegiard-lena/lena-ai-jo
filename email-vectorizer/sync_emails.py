"""
Incremental Email Sync
Detects new/updated emails since last sync and upserts only those to Qdrant.
Tracks state in sync_state.json — safe to run repeatedly.

Usage:
  python sync_emails.py          # sync new emails since last run
  python sync_emails.py --full   # force full re-sync (resets state)

Requires: Outlook open + Qdrant running + Ollama running
"""

import argparse
import hashlib
import json
import sys
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

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
BATCH_SIZE = 32
MAX_TEXT_LEN = 1000
STATE_FILE = Path(__file__).parent / "sync_state.json"

# ── State management ───────────────────────────────────────────────────────────

def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"last_sync": None, "total_synced": 0}


def save_state(last_sync: str, total: int):
    STATE_FILE.write_text(json.dumps({
        "last_sync": last_sync,
        "total_synced": total,
    }, indent=2))


# ── Ollama embedding ────────────────────────────────────────────────────────────

def ollama_embed(texts: list) -> list:
    data = json.dumps({"model": MODEL_NAME, "input": texts}).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/embed",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.load(resp)["embeddings"]


# ── Helpers ────────────────────────────────────────────────────────────────────

def email_id(subject: str, sent_on: str, sender: str) -> str:
    raw = f"{subject}|{sent_on}|{sender}"
    return hashlib.sha256(raw.encode()).hexdigest()


def safe_str(value) -> str:
    try:
        return str(value) if value else ""
    except Exception:
        return ""


def build_text(email: dict) -> str:
    parts = []
    if email["subject"]:
        parts.append(f"Subject: {email['subject']}")
    if email["sender"]:
        parts.append(f"From: {email['sender']}")
    if email["body"]:
        parts.append(email["body"])
    return "\n".join(parts)


def extract_since(folder, emails: list, since_dt: datetime | None):
    """Extract emails from folder tree, optionally filtered by ReceivedTime."""
    try:
        items = folder.Items
        if since_dt is not None:
            # Outlook restriction format: MM/DD/YYYY HH:MM AM/PM
            date_str = since_dt.strftime("%m/%d/%Y %I:%M %p")
            items = items.Restrict(f"[ReceivedTime] >= '{date_str}'")
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
            extract_since(sub, emails, since_dt)
    except Exception:
        pass


# ── Main ────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--full", action="store_true", help="Force full re-sync")
    args = parser.parse_args()

    state = load_state()
    sync_start = datetime.now(UTC).isoformat()

    if args.full:
        print("=== Full re-sync requested — resetting state ===")
        state = {"last_sync": None, "total_synced": 0}
    else:
        last = state.get("last_sync")
        print("=== Incremental Email Sync ===")
        print(f"Last sync: {last or 'never (first run = full sync)'}")

    # Parse last_sync datetime
    since_dt = None
    if state.get("last_sync"):
        try:
            since_dt = datetime.fromisoformat(state["last_sync"])
            if since_dt.tzinfo is None:
                since_dt = since_dt.replace(tzinfo=UTC)
        except ValueError:
            since_dt = None

    # Connect to Qdrant
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
            client.create_collection(
                collection_name=COLLECTION_NAME,
                vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
            )
        print(f"  Qdrant OK — {info.points_count:,} existing vectors")
    except Exception:
        print(f"  Creating collection '{COLLECTION_NAME}'...")
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
        )

    # Connect to Outlook
    print("\nConnecting to Outlook...")
    try:
        pythoncom.CoInitialize()
        try:
            outlook = win32com.client.GetActiveObject("Outlook.Application")
        except Exception:
            outlook = win32com.client.Dispatch("Outlook.Application")
        namespace = outlook.GetNamespace("MAPI")
    except Exception as e:
        print(f"ERROR: Cannot connect to Outlook: {e}")
        print("Make sure Outlook is open and running.")
        sys.exit(1)

    # Extract new emails
    filter_desc = f"since {since_dt.strftime('%Y-%m-%d %H:%M')}" if since_dt else "all emails"
    print(f"Extracting emails ({filter_desc})...")

    new_emails = []
    for account in namespace.Accounts:
        print(f"  Account: {account.DisplayName}")
        try:
            root = namespace.Stores[account.DisplayName].GetRootFolder()
            extract_since(root, new_emails, since_dt)
        except Exception as e:
            print(f"  Warning: {account.DisplayName}: {e}")

    if not new_emails:
        print("\nNo new emails found since last sync.")
        save_state(sync_start, state.get("total_synced", 0))
        return

    print(f"Found {len(new_emails):,} new/updated emails.")

    # Embed
    print(f"\nEmbedding {len(new_emails):,} emails via Ollama ({MODEL_NAME})...")
    texts = [build_text(e) for e in new_emails]
    vectors = []
    for i in tqdm(range(0, len(texts), BATCH_SIZE), desc="Embedding"):
        batch = texts[i : i + BATCH_SIZE]
        vectors.extend(ollama_embed(batch))

    # Upsert
    print(f"Upserting {len(new_emails):,} vectors to Qdrant...")
    upsert_batch = 256
    for i in tqdm(range(0, len(new_emails), upsert_batch), desc="Upserting"):
        chunk_emails = new_emails[i : i + upsert_batch]
        chunk_vectors = vectors[i : i + upsert_batch]
        points = [
            PointStruct(
                id=int(email["id"][:8], 16),
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

    total = state.get("total_synced", 0) + len(new_emails)
    save_state(sync_start, total)

    info = client.get_collection(COLLECTION_NAME)
    print("\n=== Sync complete ===")
    print(f"  New emails synced: {len(new_emails):,}")
    print(f"  Total in Qdrant:   {info.points_count:,}")
    print(f"  State saved:       {STATE_FILE}")


if __name__ == "__main__":
    main()
