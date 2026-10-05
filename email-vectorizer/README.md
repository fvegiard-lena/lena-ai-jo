# email-vectorizer — recherche dans les courriels

Courriels Outlook → embeddings Ollama (`qwen3-embedding:8b`, 4096 dimensions, cosinus) → Qdrant (collection `emails`), plus le serveur MCP `email-search` pour Claude Desktop.

Pile : Python (uv), `qdrant-client`, appels HTTP en bibliothèque standard vers Ollama, `pywin32` pour Outlook, SDK officiel `mcp` pour le serveur. Pas de PyTorch ni de sentence-transformers : c'est Ollama qui calcule les embeddings (sur la carte graphique).

> **En pause.** Rien à vectoriser tant que l'incident OST du 2026-08-31 n'est pas réglé par Jo (voir [`docs/RUNBOOK.md`](../docs/RUNBOOK.md) §2).

## Prérequis

- Outlook ouvert, comptes configurés.
- Qdrant en marche : http://localhost:6333/healthz (tâche `Qdrant Vector DB`). Pas d'interface web sur cette version : `/dashboard` donne 404, c'est normal.
- Ollama en marche avec le modèle : `ollama pull qwen3-embedding:8b`.
- `uv` (géré par mise).

## Lancer

Depuis `%USERPROFILE%\email-vectorizer` (raccourci vers `lena-ai-jo\email-vectorizer`) :

| Quoi | Commande | Raccourci |
|---|---|---|
| Tout indexer (premier passage) | `uv run python vectorize_emails.py` | `run_vectorize.bat` |
| Juste les nouveaux (incrémental, état dans `sync_state.json`) | `uv run python sync_emails.py` (`--full` pour tout reprendre) | `run_sync.bat` |
| Chercher en ligne de commande | `uv run python search_emails.py "facture en retard"` | — |

`uv` installe tout seul les dépendances la première fois (`uv sync` pour le faire d'avance).

## Brancher `email-search` dans Claude Desktop

Claude Desktop **fermé** (sinon il efface `mcpServers`, voir RUNBOOK §6), dans `%APPDATA%\Claude\claude_desktop_config.json` :

```json
"email-search": {
  "command": "uv",
  "args": [
    "run", "--project", "C:\Users\<compte>\dev\lena-ai-jo\email-vectorizer",
    "python", "C:\Users\<compte>\dev\lena-ai-jo\email-vectorizer\email_search_mcp.py"
  ]
}
```

Mettre le vrai chemin : Claude Desktop ne développe pas `%USERPROFILE%`. Si `uv` est introuvable, utiliser le chemin complet du shim mise (`C:\Users\<compte>\AppData\Local\mise\shims\uv.exe`).

Outils exposés :

| Outil | Arguments | Retour |
|---|---|---|
| `search_emails` | `query` (texte), `limit` (entier, 10 par défaut) | Liste JSON : score, sujet, expéditeur, date, dossier, aperçu |
| `email_stats` | — | JSON : nombre de courriels indexés, modèle, état |

## Tests

Depuis la racine du repo (le chemin `email-vectorizer` à la fin compte : sans lui, pytest ramasse aussi les tests des autres dossiers) :

```powershell
uv run --project email-vectorizer pytest -q email-vectorizer
uv run --project email-vectorizer ruff check email-vectorizer
```

Le test démarre le serveur en stdio avec le client du SDK et liste les outils : ça marche sans Qdrant ni Ollama. Le test de recherche est sauté si la collection `emails` ou le modèle manque.

## Comptes indexés

- le compte Outlook de Jo (OST d'environ 37 Go)
- la boîte de service partagée (OST d'environ 13 Go)

## Fichiers

| Fichier | Rôle |
|---|---|
| `vectorize_emails.py` | Extraction Outlook + embeddings + stockage Qdrant (tout) |
| `sync_emails.py` | Même chose, seulement les courriels reçus depuis le dernier passage |
| `search_emails.py` | Recherche sémantique en ligne de commande |
| `email_search_mcp.py` | Serveur MCP `email-search` (stdio) pour Claude Desktop |
| `tests/` | Test du serveur MCP |
