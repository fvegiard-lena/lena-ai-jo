# Prompt — Installer promptfoo + OPA et assainir l'outillage

Léna, `/oh-my-claudecode:execute`. Shell : Git Bash. Zéro question. Résultat + taux de succès à la fin.

## Objectif
Installer et configurer **promptfoo** (évaluer / calibrer les décisions LLM) et **OPA** (imposer une politique), puis garantir une chaîne d'outils sans `ENOENT`, sans `command not found`, sans version manquante.

**Ne pas mélanger :** promptfoo produit un **score / taux de réussite** ; OPA (Rego) produit un **oui / non** — jamais une probabilité. promptfoo mesure, OPA tranche.

## Étapes
1. **Audit outillage** : `echo $SHELL`, `mise doctor`, `mise ls`, `uv --version`, `bun --version`, `node --version`, `git --version`, `python --version`. Toute erreur → réparer (`mise use -g <outil>@latest`, `mise reshim`, `mise install`) et relancer l'audit jusqu'à 0 erreur.
2. **Installer promptfoo** : `bun add -g promptfoo` (fallback `npm i -g promptfoo`, fallback `npx promptfoo@latest`). Vérifier `promptfoo --version`.
3. **Installer OPA** : `mise use -g opa@latest` (fallback : binaire des releases GitHub officielles → `~/.local/bin`, `chmod +x`). Vérifier `opa version`.
4. **Créer `eval/` à la racine du repo** :
   - `eval/promptfooconfig.yaml` — 3 suites : `soumission_extraction`, `classification_bt_po`, `tri_courriels` ; providers Anthropic (Fable/Opus, Sonnet, Haiku) ; assertions `contains-json`, `llm-rubric`, `cost`, `latency`. Aucun prix, quantité ou norme inventé dans les cas de test : placeholders `[À CONFIRMER — Jo]`.
   - `eval/policies/dr_electrique.rego` — refuser toute soumission sans `prix_valide_par_jo == true`, tout déploiement sans `tests_verts == true`, toute action agent hors liste blanche. + `eval/policies/dr_electrique_test.rego`.
   - `eval/run.sh` (`#!/usr/bin/env bash`, `set -euo pipefail`) : `promptfoo eval`, `opa test eval/policies`, puis taux de succès calculé en Python et affiché.
5. **Brancher dans le workflow** : tâche `mise run eval` dans `mise.toml` ; job GitHub Actions `eval.yml` qui bloque le merge si OPA refuse ou si le score promptfoo < seuil (défaut 0.9, modifiable dans `eval/threshold.txt`).
6. **Vérifier comme un humain** : `mise run eval` passe de bout en bout, sortie propre, aucun warning ignoré. Ouvrir `promptfoo view` **via MCP Chrome** et confirmer visuellement les 3 suites + tests OPA verts. Toute recherche de solution (issues GitHub, doc, forums) passe aussi par MCP Chrome.

*(Les règles permanentes — audit outillage avant chaque tâche, LSP d'abord, solution prouvée citée — sont déjà dans `LENA.md` ; ne pas les dupliquer ici.)*

## Livraison attendue
1. Résumé court de ce qui est installé et où.
2. Chemins des fichiers créés.
3. Une phrase : comment lancer l'éval.
4. Taux de succès (checks OK / total, calculé en Python) + liste des `[À CONFIRMER — Jo]`.
