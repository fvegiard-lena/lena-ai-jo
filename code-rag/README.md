# code-rag — extraits cités des codes électriques

Recherche dans les PDF de référence (CSA 2026, NECA 2022, National Estimator 2025) et
affiche les passages pertinents **avec source, page et article**. L'outil ne rédige pas de
réponse : Léna (Claude) répond à partir des extraits, ou écrit `[À CONFIRMER — Jo]`.

Chaîne : PDF (PyMuPDF, page par page) → Ollama `qwen3-embedding:8b` (4096 dims) →
Qdrant `localhost:6333`, collection `codes_electriques`.

## Droits d'auteur

Les PDF sont achetés : ils restent **en local** dans `code-rag/data/`, dossier ignoré par git
(`.gitignore`). Ne jamais les committer ni les copier ailleurs dans le dépôt.

## Ajouter un PDF (Francis / Jo)

Prérequis : Qdrant et Ollama démarrés (`ollama pull qwen3-embedding:8b` une seule fois).

1. Copier le PDF dans `code-rag\data\` (créer le dossier au besoin). Le nom du fichier
   devient le nom de la source : `CSA 2026.pdf` → source « CSA 2026 ».
2. Lancer l'indexation :

   ```powershell
   cd "$env:USERPROFILE\dev\lena-ai-jo\code-rag"
   uv run code-rag ingest "data\CSA 2026.pdf"
   uv run code-rag ingest "data\NECA 2022.pdf" "data\National Estimator 2025.pdf"
   ```

   Si c'est interrompu, relancer la même commande : les extraits déjà indexés sont sautés
   (`--force` pour tout refaire). Une page sans texte signale un PDF non OCR.
3. Vérifier : `uv run code-rag status` (points par source, Qdrant / Ollama joignables).

### PDF protégé / couche texte factice

Symptôme : `ingest` s'arrête avec le code 3 (« Couche texte factice détectée… ») : le PDF porte
une couche texte de mots inventés posée sur une image de page, qui polluerait la recherche.
Remède : refaire la reconnaissance du texte, puis indexer le fichier obtenu :
`ocrmypdf --language fra+eng --force-ocr "data\CSA 2026.pdf" "data\CSA 2026 OCR.pdf"`
puis `uv run code-rag ingest "data\CSA 2026 OCR.pdf"` (`--allow-decoy` force, déconseillé).

## Interroger

```powershell
uv run code-rag ask "remplissage maximal d'un conduit EMT 3/4" --k 6
uv run code-rag ask "unités de main-d'œuvre conduit EMT" --source "NECA 2022"
```

Chaque extrait s'affiche ainsi : `**[CSA 2026 p.123 — 12-3000]** texte…`. L'article
(`12-3000`, `Section 4`, `Table 2`…) est repéré automatiquement dans l'extrait : il peut
manquer ou être approximatif — toujours vérifier dans le texte cité.

Dans Claude, le skill `code-electrique` fait tout cela automatiquement.

## Développement

```powershell
uv run pytest -q          # tests unitaires (+ test d'intégration si Qdrant et Ollama répondent)
uv run ruff check ; uv run ruff format --check
```
