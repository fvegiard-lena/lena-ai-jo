# CI-CD — les vérifications automatiques

Pour Francis (ou Léna). Jo : t'as rien à faire ici ; si une vérification échoue, Léna ou Francis s'en occupe.

Trois couches, de la plus simple à la plus poussée :

| Couche | Où ça roule | Quand | Ce que ça fait | Coût |
|---|---|---|---|---|
| 1. GitHub Actions `ci.yml` | Serveurs GitHub (Ubuntu) | Chaque push / PR sur `main` | Secrets (gitleaks), JSON, lint + tests | Gratuit (repo public) |
| 2. CI de nuit `lena-nightly-ci` | PC de Jo | 02:00 chaque nuit | Tests ; si rouge, Claude Code headless tente une correction | 2 $ max par nuit, seulement si rouge |
| 3. `claude-code-action` (plus tard) | Runner auto-hébergé sur le PC | Sur demande | Claude dans GitHub (issues, PR) | Abonnement Claude |

---

## 1. GitHub Actions — `.github/workflows/ci.yml`

À chaque push ou PR sur `main` :

1. **gitleaks** sur tout l'historique (`.gitleaks.toml` : règles par défaut, **aucune** exception, `docs/` compris).
2. **JSON valides** dans `config/` (`python3 -m json.tool`).
3. **plan-tools** : `uv sync --locked`, `ruff check`, `pytest`.
4. **code-rag** : `uv sync --locked`, `ruff check`, `pytest -m "not integration"` (les tests d'intégration demandent Qdrant + Ollama : en local seulement).
5. **Biome** si un `biome.json` existe.

`--locked` fait échouer la CI si `uv.lock` n'a pas suivi `pyproject.toml` : après un `uv add`, toujours commiter le `uv.lock`.
Permissions du jeton : `contents: read`, `pull-requests: read` (lecture seule).

**Aujourd'hui, c'est un statut seulement** (✓ ou ✗ sur le commit) : rien n'empêche un push rouge. Le repo est maintenant **public**, donc la protection de branche **est disponible** sur ce plan — **à activer via `gh api`** :

```powershell
gh api -X PUT repos/fvegiard-lena/lena-ai-jo/branches/main/protection `
  -H "Accept: application/vnd.github+json" `
  -F "required_status_checks[strict]=true" `
  -F "required_status_checks[contexts][]=ci" `
  -F "enforce_admins=false" `
  -F "required_pull_request_reviews=null" `
  -F "restrictions=null"
```

- `ci` = le nom du job dans `ci.yml`.
- **Garder `enforce_admins=false`** : `lena-auto-commit` et `lena-nightly-ci` poussent directement sur `main` avec le compte de Jo (admin). Avec `true`, ces pushs seraient refusés tant que la CI n'a pas passé — il faudrait alors passer par des PR.
- Vérifier : `gh api repos/fvegiard-lena/lena-ai-jo/branches/main/protection`. Retirer : `gh api -X DELETE repos/fvegiard-lena/lena-ai-jo/branches/main/protection`.
- Doc : https://docs.github.com/en/rest/branches/branch-protection#update-branch-protection

---

## 2. CI de nuit — `scripts/lena-nightly.ps1` (Claude Code headless)

Tâche planifiée **`lena-nightly-ci`** : 02:00 heure locale (suit l'heure d'été), RunLevel **Limited**, `-NonInteractive`, 2 h maximum, rattrapée au réveil si le PC dormait (`StartWhenAvailable`). Créée par `pwsh -File "$env:USERPROFILE\dev\lena-ai-jo\scripts\install-tasks.ps1"` (depuis le checkout principal seulement : le script refuse un jumeau).

### Ce que fait le script

1. `git pull --rebase --autostash origin main`. Conflit → rebase annulé, log, sortie en erreur.
2. Tests :
   ```powershell
   uv run --project plan-tools pytest -q plan-tools
   uv run --project code-rag pytest -q -m "not integration" code-rag
   ```
   Sortie complète dans `%TEMP%\lena-nightly-<date>-tests.log`.
3. **Si un test échoue** (et que `plan-tools/` et `code-rag/` n'ont pas de travail non commité — sinon : « ÉCHEC — intervention humaine », on ne mélange pas) : Claude Code en mode headless reçoit la sortie des tests sur l'entrée standard (plafonnée à 10 Mo) :
   ```powershell
   claude -p --bare --output-format json --permission-mode dontAsk --max-turns 5 --max-budget-usd 2.00 `
     --allowedTools "Read,Edit,Bash(uv run *)" `
     --append-system-prompt "Tu corriges UNIQUEMENT les tests qui échouent dans plan-tools/ et code-rag/. Pas de refactor. Réponds en français." `
     "Les tests suivants échouent : … Corrige-les, puis relance-les."
   ```
   Le script lit `.result` (résumé de Claude), `.total_cost_usd`, `.num_turns` et `.session_id` dans le JSON et les écrit dans le log.
4. Retest. **Vert** et des fichiers ont changé → `git add -- plan-tools code-rag`, commit `test(nightly): auto-fix <date>`, push. **Encore rouge** → rien n'est commité, log « ÉCHEC — intervention humaine », sortie en erreur (la tentative de Claude reste visible dans `git diff`).

`claude` absent du PATH → étape 3 sautée (log), le retest dit quand même si c'est rouge.

### Les options de `claude`, une par une

| Option | Pourquoi |
|---|---|
| `-p` | Mode non interactif : une requête, une réponse, puis ça sort. |
| `--bare` | Ignore hooks, plugins (OMC), serveurs MCP, mémoire et `CLAUDE.md` du PC : même résultat chaque nuit. **Mais** `--bare` n'utilise **que** `ANTHROPIC_API_KEY` (jamais la connexion d'abonnement). |
| `--safe-mode` | Utilisé **à la place** de `--bare` quand `ANTHROPIC_API_KEY` n'est pas définie (cas normal ici) : mêmes personnalisations coupées, mais garde la connexion Claude déjà faite sur le PC. |
| `--output-format json` | Réponse en JSON : `result`, `total_cost_usd`, `num_turns`, `session_id`… |
| `--permission-mode dontAsk` | Tout ce qui demanderait une permission est **refusé** ; seuls passent la lecture et ce que `--allowedTools` permet. |
| `--allowedTools "Read,Edit,Bash(uv run *)"` | Lire, modifier des fichiers, et lancer seulement des commandes qui commencent par `uv run`. Pas de `git`, pas de réseau. |
| `--max-turns 5` | Au plus 5 allers-retours : une correction ciblée, pas une refonte. |
| `--max-budget-usd 2.00` | **Plafond de coût : 2 $ US par nuit.** Claude s'arrête une fois le plafond atteint. |
| `--append-system-prompt "…"` | La consigne : seulement les tests en échec, pas de refactor, réponse en français. |
| ~~`--dangerously-skip-permissions`~~ | **Jamais.** |

Pour reprendre la session de Claude et voir ce qu'il a fait : `claude --resume <session_id>` (le `session_id` est dans le log).

### Journaux et essai à la main

| Quoi | Où |
|---|---|
| Déroulement + résumé de Claude + coût | `scripts\lena-nightly.log` (5 Mo max, puis repart à zéro ; jamais commité) |
| Sorties complètes des tests | `%TEMP%\lena-nightly-<date>-tests.log`, `…-retest.log` |
| Erreurs de `claude` | `%TEMP%\lena-nightly-<date>-claude.err.log` |

Essai sans risque (pas de pull, pas de Claude, pas de commit — juste les tests) :
```powershell
pwsh -NoProfile -File scripts\lena-nightly.ps1 -DryRun     # ou -WhatIf
```
Lancer la vraie tâche tout de suite : `Start-ScheduledTask -TaskName lena-nightly-ci`.

### Docs officielles

- Mode headless / `claude -p`, `--bare` et l'authentification : https://code.claude.com/docs/en/headless
- Toutes les options de la ligne de commande : https://code.claude.com/docs/en/cli-reference
- Modes de permission (`dontAsk`) : https://code.claude.com/docs/en/permission-modes

---

## 3. Plus tard : `anthropics/claude-code-action@v1` sur un runner Windows auto-hébergé

But : parler à Claude directement dans GitHub (`@claude` dans une issue ou une PR) avec un runner qui tourne **sur le PC de Jo** (accès aux outils locaux : uv, Qdrant, Ollama).

Étapes (rien n'est fait pour l'instant) :

1. Installer le runner sur le PC : GitHub → repo → Settings → Actions → Runners → *New self-hosted runner* → Windows. Doc : https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners
2. Jeton d'abonnement Claude : `claude setup-token`, puis le mettre en secret du repo (jamais dans un fichier) :
   ```powershell
   gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo fvegiard-lena/lena-ai-jo
   ```
3. Workflow `.github/workflows/claude.yml` :
   ```yaml
   name: Claude Code
   on:
     issue_comment:
       types: [created]
   jobs:
     claude:
       if: contains(github.event.comment.body, '@claude') && github.event.comment.author_association == 'OWNER'
       runs-on: [self-hosted, Windows]
       permissions:
         contents: write
         pull-requests: write
         issues: write
         id-token: write
       steps:
         - uses: actions/checkout@v6
         - uses: anthropics/claude-code-action@v1
           with:
             claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
             claude_args: "--max-turns 5"
   ```

**Attention, repo public :** GitHub déconseille les runners auto-hébergés sur un repo public — un inconnu pourrait faire exécuter du code sur le PC de Jo. D'où le filtre `author_association == 'OWNER'` ci-dessus, et : Settings → Actions → *Require approval for all outside collaborators*, ne jamais déclencher le runner sur `pull_request` venant d'un fork. Sinon, garder le runner sur un repo **privé**.

Docs :
- Claude Code GitHub Actions : https://code.claude.com/docs/en/github-actions
- L'action et ses entrées : https://github.com/anthropics/claude-code-action
- Sécurité des runners auto-hébergés : https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners
