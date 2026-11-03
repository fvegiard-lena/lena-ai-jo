# Kit agents — dépôt du 2026-11-03 (pour le Mayor Gas Town)

**Nature : exemples de code + jeu de données de référence.** Rien ici n'est activé dans le dépôt.
Ce sont des matériaux à étudier, adapter et tester — pas à copier tels quels dans `.claude/`.

Source : fichiers fournis par Francis (sortie DeepSeek du 2026-11-02 + arbres de dépôts exportés), déposés par Claude.

## Contenu

| Dossier | Quoi | Usage |
|---|---|---|
| `arbres-repos/` | Arbres de fichiers complets de `fvegiard/OpenHands` (main, branche agent-canvas) et `fvegiard/oh-my-openagent` (dev) | Jeu de données : carte des dépôts pour planifier sans tout cloner |
| `hooks/` | 7 hooks Claude Code (bash) : `pre-bash-guard`, `pre-write-provenance`, `post-edit-verify`, `post-bash-capture`, `stop-gate`, `subagent-stop-gate`, `git-pre-commit` | Exemples de code — contrat d'agent « zéro faux fait » |
| `config/` | `claude-settings.hooks.json` (câblage des hooks), `mcp.json` (7 serveurs MCP) | Exemples de config |
| `pseudo-code/` | Boucles `correct()`, `exhaust_search()`, `clean_room()`, `self_correct()`, `ROUTE()` | Spécification du flux de contrôle |
| `diagrammes/` | 7 Mermaid + rendus PNG (machine à états, séquences, porte d'arrêt, escalade) | Spec visuelle |
| `captures/` | Table de routage MCP §4.1, résumé type §5.2, « comment tout se connecte » | Référence |

Correspondance noms d'origine → hooks : `00d8ec`=pre-bash-guard, `9bb768`=pre-write-provenance,
`ba8e84`=post-edit-verify, `6052b5`=post-bash-capture, `3f457d`=stop-gate, `b63d3e`=subagent-stop-gate,
`29ef2c`=git-pre-commit.

## Validé (2026-11-03)
- `bash -n` OK sur les 7 hooks ; les 2 JSON passent `json.tool`.
- Doublons retirés : `openhands-agent-canvas-tree (1).txt` = `openhands-agent-canvas-tree.txt` (même sha256) ;
  le zip `oh-my-openagent-dev-tree.zip` ne contenait que ces mêmes 5 arbres.

## Défauts connus — à corriger AVANT toute activation (testés, pas supposés)
1. **`pre-bash-guard.sh` ne bloque pas `pip install` global** : `grep -E` ne supporte pas `(?!…)` (lookahead PCRE).
   Test : `pip install requests` → exit 0 (attendu 2) ; `npm install -g x` → exit 2 (OK). Corriger avec `grep -P`
   ou un test séparé `pip install` + absence de `.venv`.
2. **`stop-gate.sh` §4 ne bloque jamais** : il compare le nombre de lignes « edited » de `verify.log` au nombre total
   de lignes du même fichier, toujours égaux puisque `post-edit-verify.sh` n'écrit que des lignes « edited ».
3. **`git-pre-commit.sh` §5 lit `.git/COMMIT_EDITMSG` au moment du pre-commit** : à ce stade c'est le message du
   commit PRÉCÉDENT. La vérification `Source:` doit aller dans un hook `commit-msg` (qui reçoit le fichier en `$1`).
4. **Blockers à signaler à Francis avant adoption** (règle 1) : `stop-gate` bloque tout arrêt sans
   `tasks/.logs/clean-room.log` = ALL GREEN, et `pre-write-provenance` bloque toute écriture de plus de 5 lignes sans
   ligne dans `tasks/todo.md`. Ce sont des portes dures — à n'activer que là où Francis les veut.

## Consigne pour le Mayor
Utiliser ce kit comme exemples et données : en tirer les beads utiles par rig (corriger les 3 défauts ci-dessus dans
une copie, écrire les tests qui les prouvent, proposer l'intégration au contrat d'agent `AGENTS.md`), sans activer
les hooks dans un dépôt sans commit + test vert.
