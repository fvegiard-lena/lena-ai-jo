# backlog — tâches de la boucle autonome

Une tâche = un fichier Markdown. La boucle (`scripts/lena-loop.sh`) prend le premier fichier de
`todo/` par ordre alphabétique, le donne à une session neuve, puis :

| Résultat | Effet |
|---|---|
| Checks verts | commit `loop: <id>`, fichier déplacé dans `done/` |
| Checks rouges | tout est annulé (`git reset --hard`), la tâche reste dans `todo/` |
| Rouge `LENA_MAX_ATTEMPTS` fois (3 par défaut) | fichier déplacé dans `failed/`, pour un humain |

Chaque passage ajoute une ligne à `results.tsv` (racine du repo, non commité).

## Format

```markdown
# Titre court à l'impératif

Check: uv run --project plan-tools pytest -q plan-tools/tests/test_route.py

Ce qui doit être vrai à la fin, en 2 à 5 lignes. Fichiers concernés si connus.
```

- `Check:` est optionnelle mais recommandée : c'est le but vérifiable (règle 4 de LENA.md).
  Elle doit commencer par `uv run ` et ne contenir aucun de `; | & $ \` < >` (sinon la tâche échoue).
- Nom du fichier : `<AAAAMMJJ>-<mot-cle>.md` (ex. `20261010-route-panel-missing.md`).
- Jamais de prix, marge, quantité, norme ou délai dans une tâche : ces données viennent de Jo.
