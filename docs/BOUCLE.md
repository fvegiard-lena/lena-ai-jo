# Boucle autonome — Léna travaille seule sur une liste de tâches

Pour Francis. Le modèle : la boucle *autoresearch* de Karpathy et la *Ralph loop* de Geoffrey Huntley.
L'humain écrit le but (`program.md`) et les tâches (`backlog/todo/`) ; Léna fait une tâche par session
neuve ; un vérificateur automatique garde ou annule. Rien ne passe sans tests verts.

## Les pièces

| Fichier | Qui l'écrit | Rôle |
|---|---|---|
| `program.md` | Francis | Objectifs, zones permises / interdites, critère de réussite. |
| `backlog/todo/*.md` | Francis, ou Léna (tâches découvertes) | Une tâche par fichier, avec une ligne `Check:` (format : `backlog/README.md`). |
| `scripts/lena-loop.sh` | — | La boucle. |
| `scripts/lena-check.sh` | — | Le vérificateur : garde OPA, ruff, pytest, parité AGENTS.md, ligne `Check:`. |
| `policy/guard.rego` | — | Refuse : fichiers protégés modifiés, `[À CONFIRMER]` retiré, montant en $ ajouté hors tests. |
| `results.tsv` | la boucle | Une ligne par passage : tâche, essai, keep / revert, coût, durée, session. Non commité. |

## Lancer

Depuis un checkout **propre**, sur `francis-dev` ou une branche de travail (jamais `main`), en Git Bash :

```bash
bash scripts/lena-loop.sh                                # valeurs par défaut
LENA_BUDGET_USD=50 LENA_MAX_ITER=200 bash scripts/lena-loop.sh
touch STOP                                               # arrêt propre après le passage en cours
```

| Variable | Défaut | Effet |
|---|---|---|
| `LENA_BUDGET_USD` | 20 | Coût total maximum de la boucle. |
| `LENA_TASK_BUDGET_USD` | 2 | Coût maximum d'une session (`--max-budget-usd`). |
| `LENA_MAX_TURNS` | 40 | Tours maximum d'une session. |
| `LENA_MAX_ITER` | 1000 | Passages maximum. |
| `LENA_MAX_ATTEMPTS` | 3 | Essais par tâche avant `backlog/failed/`. |
| `LENA_MAX_FAIL_STREAK` | 5 | Arrêt après N passages rouges d'affilée. |
| `LENA_PLAN` | 1 | Backlog vide → une session de planification qui peut créer des tâches. |

La boucle commite sur la branche courante et **ne pousse jamais** : on relit `git log`, puis PR vers `main`.

## Sécurité

- Chaque session : `claude -p --permission-mode dontAsk`, outils limités à lire / écrire des fichiers et
  `uv run|sync|add`. Pas de `git`, pas de réseau hors `uv`, pas de MCP (`--safe-mode` / `--bare`), donc
  pas de Gmail, de navigateur ni de secrets : la boucle ne combine jamais données privées, contenu non
  fiable et sortie vers l'extérieur.
- Tout ce que la boucle refuse est annulé par `git reset --hard` : seul le travail vérifié reste.
- Prix, marges, quantités, normes, délais : interdits dans la boucle (LENA.md + garde OPA).

## Paralléliser

Une boucle par dossier : `git worktree add ../lena-loop-2 -b loop-2`, chaque branche avec ses propres
fichiers dans `backlog/todo/` (pas la même tâche dans deux branches), puis fusion par PR.

## Tester sans rien dépenser

```bash
bash scripts/test-lena-loop.sh    # agent simulé : keep, revert, failed, garde OPA, refus de main
opa test policy/ -v
```
