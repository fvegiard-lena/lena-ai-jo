# Inventaire — état au 2026-10-05

Photo de la machine de Jo le jour où le repo a été structuré, mise à jour en fin de journée.

## État

| Élément | État constaté | Suite |
|---|---|---|
| Repo `lena-ai-jo` | 1 seul commit ; `scripts/` et `.claude/` non suivis | Structuré (ce lot) |
| Tâche `lena-claude-backup` | **Brisée depuis 2026-08-03** : `0x80070002`, chemin pwsh 7.6.3 figé | `scripts/install-tasks.ps1` (alias pwsh stable) |
| Tâche `Desktop Commander Remote` | Était morte (`0xC000013A`, appareil hors ligne 161 h). Relancée par `Start-ScheduledTask` sans ré-appairage : appareil « Jo » **en ligne depuis 14:00** | Déclencheur horaire ajouté par `install-tasks.ps1` (RUNBOOK §3) |
| Tâche `lena-ai-jo-copilot-sync` | Roulait chaque jour, Copilot jamais authentifié (log) | Retirée par `install-tasks.ps1` ; script et log supprimés |
| Tâche `lena-nightly-ci` | Nouvelle : tests de nuit + correction par Claude Code headless | Créée par `install-tasks.ps1` ([CI-CD](CI-CD.md)) |
| Tâche `Qdrant Vector DB` | Sortie `0xC000013A` à 06:23, relancée : **en marche** (`/healthz` OK). La collection `emails` n'existe pas encore | Recréée à la vectorisation, après l'incident OST |
| Claude Desktop `mcpServers` | `{}` (vide) | À remettre Desktop fermé (RUNBOOK §6) |
| Outlook OST | Incident du 2026-08-31 en attente | Rien sans Jo (RUNBOOK §2) |
| Google Drive | OK | — |
| OneDrive `Mes projets` | 388 dossiers projets · 371 `.qpl` · 14 674 PNG · 218 PDF | Source de `plan-tools` |
| `email-vectorizer` | Hors repo (`~/email-vectorizer`) | Déplacé dans le repo, raccourci (junction) à l'ancien endroit |
| Agent Canvas (OpenHands) | Installé, lancé par le raccourci « Agent Canvas (Léna) » | RUNBOOK §7 |

## Versions

Tout est à jour, sauf le plugin OMC.

| Outil | Version | Géré par |
|---|---|---|
| Claude Code | 2.1.289 | installateur natif (`claude update`) |
| OMC (oh-my-claudecode) | 5.1.0 — la 5.6.1 est sortie, mise à jour prévue en fin de session | plugin Claude Code |
| mise | 2026.10.3 | winget (épinglé) |
| node | 24.21.0 | mise |
| uv | 0.12.23 | mise |
| go | 1.27.1 | mise |
| opa | 1.21.1 | mise |
| biome | 2.5.15 | mise (`npm:`) |
| promptfoo | 0.123.1 | mise (`npm:`) |
| Desktop Commander | 0.2.52 | mise (`npm:`) |
| Agent Canvas | 1.24.0 | `npx -y @openhands/agent-canvas@latest` (pas d'installation globale) |
| Qdrant | 1.17.0 | `%USERPROFILE%\qdrant`, tâche `Qdrant Vector DB` |

Les versions vivantes sont dans [`config/VERSIONS.md`](../config/VERSIONS.md) (régénéré chaque jour par `scripts/snapshot-config.ps1`).
