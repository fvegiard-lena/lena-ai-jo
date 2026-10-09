---
name: code-electrique
description: Réponses citées sur les codes électriques et les références d'estimation de DR Électrique (CSA 2026, NECA 2022 unités de main-d'œuvre, National Estimator 2025). À utiliser quand Jo parle de « code », « CSA », « CÉQ », « article », « remplissage conduit », « calibre », « NECA », « unités de main-d'œuvre », « taux », ou demande ce qu'exige une règle, une ampacité, un remplissage de conduit ou un temps d'installation.
---

# code-electrique — réponses citées, jamais inventées

Outil : `code-rag` du checkout courant (`lena-ai-jo` ou un jumeau, RUNBOOK §11) (recherche dans les PDF indexés ;
il affiche des extraits, il ne rédige pas la réponse).
Commandes : depuis la racine du checkout (le dossier de travail de Claude Code), en PowerShell ou Git Bash.

## Étapes

1. **Vérifier que la source est indexée** :
   ```powershell
   uv run --project code-rag code-rag status
   ```
   Source attendue : code / CSA / CÉQ / article / calibre / remplissage → « CSA 2026 » ;
   unités de main-d'œuvre / taux / NECA → « NECA 2022 » et/ou « National Estimator 2025 ».
   - Si la source n'apparaît pas dans la liste (0 point) ou si la collection est absente :
     répondre « La source « … » n'est pas encore ingérée dans code-rag. » et **s'arrêter**.
   - Si Qdrant ou Ollama est en `PROBLÈME` : transmettre le message à Jo et s'arrêter.
2. **Chercher les extraits** :
   ```powershell
   uv run --project code-rag code-rag ask "<question>" --k 6
   ```
   Ajouter `--source "CSA 2026"` (ou `"NECA 2022"`, `"National Estimator 2025"`) quand la
   question vise clairement une source. NECA et National Estimator sont en anglais : si rien
   ne répond, relancer une fois avec les termes anglais (ex. « EMT conduit labor units »).
3. **Lire les extraits** : chaque bloc commence par `**[source p.page — article]**`.
4. **Répondre en français, court**, avec une citation par affirmation :
   `(CSA 2026, p.X, art. Y)` — page tirée de l'en-tête de l'extrait ; `art. Y` seulement si
   ce numéro figure **littéralement** dans le texte de l'extrait, sinon `(CSA 2026, p.X)`.
   Si aucun extrait ne répond à la question : `[À CONFIRMER — Jo]` + ce qui manque.

## Règles

- Ne jamais citer un numéro d'article, de table ou une valeur (A, %, heures, calibre) absent
  des extraits ; ne jamais compléter avec des connaissances générales ou le web.
- Recopier les valeurs exactement (avec unités et conditions : colonne, température,
  facteur de difficulté…) ; si la condition n'est pas visible dans l'extrait → `[À CONFIRMER — Jo]`.
- L'`article` de l'en-tête est repéré automatiquement : il peut être faux ou absent ; se fier
  au texte de l'extrait.
- CÉQ : si l'extrait vient du code canadien (CSA) et que Jo demande la règle québécoise,
  préciser que les modifications du Québec peuvent différer → `[À CONFIRMER — Jo]`.
- Droits d'auteur : citer au plus une ou deux phrases ; ne jamais recopier de longs passages
  ni les PDF.
