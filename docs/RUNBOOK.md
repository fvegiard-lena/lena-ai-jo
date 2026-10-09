# RUNBOOK — si quelque chose casse

Pour Francis (ou Léna). Jo : si t'es pas sûr, appelle Francis. Les commandes se tapent dans **PowerShell 7** (`pwsh`).

---

## 1. Qdrant ne répond plus (recherche de courriels morte)

**Vérifier :**
```powershell
Invoke-WebRequest http://localhost:6333/healthz
```
(C'est `/healthz`, pas `/health`. `/dashboard` donne 404 sur cette version : normal.)

**Relancer :**
```powershell
Start-ScheduledTask -TaskName "Qdrant Vector DB"
```

**Règle d'or :** dans `%USERPROFILE%\qdrant\config.yaml`, `storage_path` et `snapshots_path` doivent être des chemins **absolus** écrits en toutes lettres (`C:/Users/<compte>/qdrant/storage`, pas `./storage` ni `%USERPROFILE%` : Qdrant ne les développe pas). La copie dans `config/qdrant/` est masquée (`%USERPROFILE%`) : remettre le vrai chemin avant de la restaurer. La tâche n'a pas de dossier de travail : un chemin relatif atterrit dans `C:\Windows\System32` et Qdrant plante (erreur 1067).
Modifier `config.yaml` : pas besoin d'admin. Modifier la tâche elle-même (RunLevel Highest) : PowerShell **admin**.

---

## 2. Outlook / fichier OST (incident du 2026-08-31)

**On ne touche à rien sans Jo.** Pas de `scanpst`, pas de reconstruction, pas de suppression d'OST, pas de vectorisation des courriels.
Jo vérifie d'abord ses courriels lui-même, ensuite on décide ensemble.

---

## 3. Desktop Commander Remote : appareil « Jo » hors ligne

claude.ai ne rejoint plus le PC.

**Vérifier :** depuis claude.ai, l'outil `list_devices` du connecteur Desktop Commander (appareil « Jo » : Online / Offline).
`desktop-commander --version` **n'est pas une option** : la commande démarre le serveur stdio et reste bloquée. Ne pas s'en servir pour tester.

**Réparer (dans l'ordre) :**
1. Relancer la tâche — ça suffit presque toujours :
   ```powershell
   Start-ScheduledTask -TaskName "Desktop Commander Remote"
   ```
   Le 2026-10-05 : la tâche était morte (`0xC000013A`) ; cette commande a remis l'appareil Online **sans ré-appairage**.
2. Attendre une minute, refaire `list_devices`.
3. **Seulement si c'est encore Offline** : ré-appairer. Fenêtre PowerShell **visible** :
   ```powershell
   desktop-commander remote
   ```
   Le navigateur s'ouvre : se connecter et **confirmer le code** affiché. Quand c'est « connecté », fermer la fenêtre et refaire l'étape 1.

Desktop Commander 0.2.52 est géré par mise (voir §5). La tâche se relance toute seule chaque heure si elle est morte. Elle doit rester en RunLevel **Limited** (jamais « exécuter avec les privilèges les plus élevés »).
Pour la recréer proprement : `pwsh -File "$env:USERPROFILE\dev\lena-ai-jo\scripts\install-tasks.ps1"` (met à jour sur place, et relance le process s'il tournait hors de la tâche). Toujours depuis le checkout principal : le script refuse de tourner depuis un jumeau (§11).

---

## 4. La sauvegarde (`lena-claude-backup`) ne roule plus

**Symptôme :** dernier résultat `0x80070002` (fichier introuvable).
**Cause :** la tâche pointait sur un chemin pwsh figé (`Program Files\WindowsApps\Microsoft.PowerShell_7.6.3…`) qui disparaît à chaque mise à jour de PowerShell.

**Réparer :**
```powershell
pwsh -File "$env:USERPROFILE\dev\lena-ai-jo\scripts\install-tasks.ps1"
Get-ScheduledTask lena-claude-backup | Get-ScheduledTaskInfo
```
Le script utilise l'alias stable `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`.

---

## 5. mise gère tous les outils npm (commandes disparues après une mise à jour)

**Symptôme :** `promptfoo`, `desktop-commander`, `biome`… introuvables.
**Cause :** un `npm install -g` vit dans le dossier d'**une** version de node ; nouvelle version = outils partis.

**La règle :** mise possède **tous** les outils npm de la machine (`~/.config/mise/config.toml`, lignes `npm:`) : `desktop-commander`, `promptfoo`, `typescript`, `typescript-language-server`, `vscode-langservers-extracted`, `yaml-language-server` (et `biome`). **Jamais de `npm i -g`.**

**Après chaque mise à jour, ou si une commande a disparu :**
```powershell
mise upgrade
mise reshim
```
(`mise install` puis `mise reshim` si un outil manque sans mise à jour.) `mise reshim` remet les raccourcis dans `%LOCALAPPDATA%\mise\shims`, le seul de ces dossiers qui est sur le PATH.

---

## 6. Claude Desktop a effacé les serveurs MCP (`mcpServers` vide)

**Cause :** Claude Desktop réécrit `%APPDATA%\Claude\claude_desktop_config.json` pendant qu'il roule. Les `preferences` survivent, `mcpServers` saute.

**Serveurs attendus :**

| Nom | Rôle | Commande |
|---|---|---|
| `email-search` | Recherche dans les courriels (Qdrant + Ollama) | `uv run --project <repo>\email-vectorizer python <repo>\email-vectorizer\email_search_mcp.py` (détails : `email-vectorizer/README.md`) |
| `filesystem` | Accès aux fichiers | serveur MCP officiel `@modelcontextprotocol/server-filesystem`, dossiers permis : `C:\Users\<compte>` et `D:\GitHub` |

```json
"mcpServers": {
  "email-search": {
    "command": "uv",
    "args": ["run", "--project", "C:\\Users\\<compte>\\dev\\lena-ai-jo\\email-vectorizer",
             "python", "C:\\Users\\<compte>\\dev\\lena-ai-jo\\email-vectorizer\\email_search_mcp.py"]
  },
  "filesystem": {
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\Users\\<compte>", "D:\\GitHub"]
  }
}
```
Mettre les vrais chemins (Claude Desktop ne développe pas `%USERPROFILE%`).

**Réparer :**
- **Ferme complètement** Claude Desktop (icône près de l'horloge → Quitter), édite le fichier, rouvre ; **ou**
- Ajoute les serveurs par l'interface : Réglages → Extensions / Connecteurs.

---

## 7. Agent Canvas (OpenHands)

**Lancer :** raccourci de bureau **« Agent Canvas (Léna) »**, qui fait :
```powershell
npx -y @openhands/agent-canvas@latest
```
**Pas** d'installation globale (ni mise, ni `npm i -g`) : l'arborescence npm de mise dépasse la limite Windows de 260 caractères (MAX_PATH) et le serveur statique meurt avec `spawn node.exe ENOENT`. `npx` n'a pas ce problème.

| Port | Rôle |
|---|---|
| 8000 | Interface (UI) |
| 18000 | agent-server |
| 18001 | automatisation |
| 3001 | serveur statique |

- **État / réglages :** `%USERPROFILE%\.openhands\agent-canvas`.
- **Premier lancement :** choisir **Claude Code** comme agent. Il utilise la connexion Claude déjà faite sur le PC : **pas de clé API**.
- **Limite connue :** les skills de Claude Code ne sont pas toutes visibles à travers ACP (OpenHands, issue #16905). Les skills de Jo vivent dans Claude Desktop / Claude Code : pour elles, passer par là.
- **Ça ne démarre pas :** un des ports ci-dessus est peut-être déjà pris. Pour voir qui l'occupe : `Get-NetTCPConnection -LocalPort 8000,18000,18001,3001 -State Listen`.

---

## 8. Stockage privé (config brute, non masquée)

- `config/` dans ce repo (public) est **masquée** : secrets, identité, identifiants de comptes.
- La copie **brute** (non masquée) vit dans `D:\Backups\claude` (sous-dossier `config\` : `.claude.json`, `CLAUDE.md`, `settings.json`, `keybindings.json`), copiée par la tâche `lena-claude-backup`. Ne jamais la mettre dans le repo.
- **Cloudflare R2 : pas encore activé** (étape à faire par Francis dans le tableau de bord Cloudflare). Une fois activé, `scripts/auto-commit.ps1` pourra y téléverser un zip de la config brute.

---

## 9. La CI de nuit (`lena-nightly-ci`) a échoué

Voir [CI-CD.md](CI-CD.md). En bref : lire `scripts\lena-nightly.log`. « ÉCHEC — intervention humaine » veut dire que les tests restent rouges même après la tentative de Claude ; rien n'a été commité.

---

## 10. Codes électriques (`code-rag`) : le PDF a une « couche texte factice »

**Symptôme (vu le 2026-10-05 avec `CSA 2026.pdf`)** : `code-rag ask` renvoie du charabia (« cicaan vedet temppelici … »). Le PDF protégé contient une image par page et, par-dessus, un texte bidon anti-copie. `code-rag ingest` refuse maintenant ce genre de fichier (code de sortie 3) au lieu d'indexer du bruit.

**Quoi faire** :
1. Passer le PDF à l'OCR comme pour `Neca 2022 OCR.pdf` et `national estimator 2025 OCR.pdf` (Francis a le flux ; sinon `ocrmypdf --language fra+eng --force-ocr "CSA 2026.pdf" "CSA 2026 OCR.pdf"` — Tesseract + Ghostscript à installer **en admin**, donc pas depuis une session Léna sans surveillance).
2. Déposer le fichier OCR dans OneDrive `DANIEL-FRANCIS-JO\_CODES\` (synchronisé localement, jamais dans le repo) ou dans `code-rag\data\`.
3. `uv run --project "$env:USERPROFILE\dev\lena-ai-jo\code-rag" code-rag ingest "<chemin du PDF OCR>" --source "CSA 2026"` puis `code-rag status` doit montrer des points pour la source.
4. Vérifier : `code-rag ask "remplissage maximal d'un conduit EMT" --k 3` doit renvoyer du vrai texte avec `p.<page>`.

Les PDF des normes restent **locaux** (droits d'auteur) : `code-rag/data/` est ignoré par git.

---

## 11. Installer un jumeau de Léna (Francis dev, estimateur junior)

Un jumeau = un deuxième checkout du repo, sur sa propre branche, à côté de `lena-ai-jo`. Même code, mêmes skills, mêmes règles ; chacun travaille sur sa branche et fait une PR vers `main`.

| Branche | Dossier (sous `<Root>`, `%USERPROFILE%\dev` par défaut) | Pour qui | Compte Claude (décision de Francis, 2026-10-09) | Dossier de config Claude Code |
|---|---|---|---|---|
| `francis-dev` | `lena-francis-dev` | Francis (développement) | `fvegiard@gmail.com` | `%USERPROFILE%\.claude-francis` |
| `Estimateur-2` | `lena-Estimateur-2` | Estimateur 2 | `lena.ai.dr.routeur@gmail.com` (pour le moment) | `%USERPROFILE%\.claude-routeur` |
| `estimateur-junior` | `lena-estimateur-junior` | Les autres estimateurs | `lena.ai.dr.routeur@gmail.com` (pour le moment, même login que l'estimateur 2) | `%USERPROFILE%\.claude-routeur` |

Chaque jumeau roule sous **son** compte Claude, même sur un PC où un autre compte est déjà connecté (PC de Jo, PC de Francis) : le script crée un dossier de config Claude Code par compte (`%USERPROFILE%\.claude-<clé>`, variable `CLAUDE_CONFIG_DIR`) et un lanceur `<Root>\lena-<branche>.cmd` qui pose cette variable, va dans le jumeau et lance `claude`. Le compte principal du PC (`%USERPROFILE%\.claude`) n'est jamais touché. Première fois dans un jumeau : `/login` avec le compte de la table (une fois par dossier de config : Estimateur-2 et estimateur-junior partagent le login routeur). `-SharedLogin` désactive ça (jumeaux sous le compte déjà connecté, lanceur sans `CLAUDE_CONFIG_DIR`). Desktop Commander reste appairé par compte claude.ai (§3), pas par dossier : un compte ne voit que les appareils qu'il a appairés.

**Installer ou mettre à jour (PC de Jo, ou le PC d'un autre estimateur), dans l'ordre :**
1. Outils de base, une fois, sans admin (rouvrir le terminal après) : `winget install --id Git.Git -e` et `winget install --id Microsoft.PowerShell -e --scope user` (le script exige PowerShell 7).
2. Le repo, s'il n'est pas déjà là : `git clone https://github.com/fvegiard-lena/lena-ai-jo.git "$env:USERPROFILE\dev\lena-ai-jo"`. Repo déjà cloné ailleurs (PC de Francis : `D:\github\lena-ai-jo`) : ajouter `-Root D:\github` à la commande suivante, les jumeaux et les lanceurs se mettent à côté.
3. Le script, depuis un terminal Windows normal :
   ```powershell
   pwsh -File "$env:USERPROFILE\dev\lena-ai-jo\scripts\install-twin.ps1"
   ```
   Une seule branche (ex. le PC de l'estimateur 2) : `-Branch Estimateur-2` ; plusieurs : `-Branch francis-dev,Estimateur-2`. Sans les tests : `-SkipTests`. Sans installer d'outil : `-NoInstall`. Pour voir sans rien faire (rien n'est écrit, pas même la config git) : `-WhatIf`.
4. Dans chaque jumeau, par son lanceur : `/login` avec le compte de la table, puis `/status` doit montrer ce compte (le dossier démarre sans compte). Ensuite `/plugin` → installer `oh-my-claudecode` (marketplace `omc`, comme sur le PC de Jo, voir `config\claude\settings.json`) ; sans lui, Léna fonctionne avec Claude Code nu (LENA.md, étape 4 du workflow, sans `/oh-my-claudecode:execute`).

Le script : vérifie `git`, `mise`, `uv`, `node`, `claude` et installe ce qui manque (`winget` pour git et mise, `mise use -g` pour uv et node, installateur officiel `claude.ai/install.ps1` pour Claude Code ; un outil installé pendant le script peut demander de rouvrir le terminal et relancer) ; ajoute une fois `%LOCALAPPDATA%\mise\shims` au PATH utilisateur (sinon node et uv de mise sont invisibles aux sessions lancées par le lanceur) ; clone ou met à jour chaque jumeau (`git pull --ff-only`, jamais de reset ; un jumeau laissé sur une autre branche est seulement « fetché », pas basculé ; un jumeau dont `origin` n'est pas le bon repo est signalé, pas tiré) ; écrit `CLAUDE.local.md` (ignoré par git, jamais réécrit s'il existe déjà) qui importe `docs\LENA.md` pour que Claude Code lancé dans ce dossier **soit** Léna ; crée le dossier de config du compte et y copie `config\claude\settings.json` du repo (même réglages pour tous, sans `statusLine` ni `enabledPlugins`, propres à un PC ; jamais réécrit s'il existe) ; écrit le lanceur (régénéré à chaque passage ; il refuse de partir depuis un terminal de Claude Desktop/Code, coupe l'auto-mise-à-jour du binaire `claude` partagé et les jetons API de l'environnement) ; retire d'un dossier de config jamais connecté l'identité d'un autre compte (`.claude.json`) ; pose l'identité git du jumeau (`Léna (<branche>)`, adresse noreply du compte GitHub `fvegiard-lena`) seulement si aucune n'est configurée (un estimateur qui veut ses commits à son nom fait `git config --global user.name "…"` et `user.email "…"` avant) ; `uv sync --locked` et les mêmes tests que la CI ; finit par un taux de succès (checks OK / total). Code de sortie 1 si une vérification obligatoire échoue.

**S'en servir :** double-clic sur `<Root>\lena-estimateur-junior.cmd`, ou depuis un **terminal Windows normal** (menu Démarrer → Windows Terminal), avec les mêmes arguments que `claude`. Jamais depuis un terminal ouvert dans Claude Desktop ou Claude Code : ces sessions portent l'identité du compte principal dans leur environnement et le lanceur refuse de partir (sinon le jumeau serait étiqueté avec le mauvais compte). Première fois : `/login` avec le compte du jumeau — c'est le navigateur qui décide du compte connecté, donc ouvrir d'abord une fenêtre privée connectée à claude.ai avec le bon compte. Dans un jumeau, jamais `/logout` (révoque le login côté serveur) ni `/chrome` (réécrit le pont Chrome du compte principal) ; pour refaire un login : supprimer `.credentials.json` et `.claude.json` du dossier de config du jumeau, puis relancer. Si un jumeau redit « Not logged in » après quelques jours (défaut connu de Claude Code avec `CLAUDE_CONFIG_DIR`), refaire `/login` par le lanceur. Les règles (LENA.md) et les skills (`.claude\skills`) sont prises dans ce dossier ; les skills appellent `plan-tools` et `code-rag` du checkout courant (jamais un chemin fixe). Les réglages semés (`config\claude\settings.json` de Jo) mettent Claude Code en `bypassPermissions`, comme chez Jo : c'est la décision de Francis pour les estimateurs ; pour changer, éditer `settings.json` du dossier de config du jumeau. Un `CLAUDE.md` placé dans un dossier parent des jumeaux (ex. `D:\github\CLAUDE.md` sur le PC de Francis) est aussi lu par Claude Code dans chaque jumeau.

**Copie conforme :** le jumeau est une copie exacte de ce que le repo contient (code, outils `plan-tools` / `code-rag`, skills, règles LENA.md, scripts, réglages Claude Code de `config\claude\settings.json`). Ce qui vit dans le **compte claude.ai** ne se copie pas par le repo et se règle une fois par compte, dans claude.ai, à la main : la liste exacte, identique pour tous les estimateurs (réglages, mémoire, langue, connecteurs Gmail / Google Drive / Google Calendar / GitHub `lena-ai-jo` / Desktop Commander (§3) / Normes DR Électrique / Slack / Cloudflare, extension Chrome), est dans `docs/COMPTE-CLAUDE.md`. Les données locales (Qdrant, Ollama, OneDrive `Mes projets`, PDF des codes) restent sur le PC de Jo : un jumeau sur un autre PC les refait pour lui (§1, §10).

**Ça ne clone pas :** le dossier existe mais n'est pas un dépôt git (le déplacer), ou pas d'accès réseau à GitHub. Les tâches planifiées (`install-tasks.ps1`) restent liées au checkout principal : le script refuse de tourner depuis un jumeau.

**Après un merge dans `main` :** un jumeau ne reçoit que sa propre branche (`git pull --ff-only`). Pour lui ramener ce qui est entré dans `main` : dans le jumeau, `git fetch origin` puis `git merge origin/main` (ou l'inverse, PR du jumeau vers `main`, quand c'est lui qui a du neuf). Le checkout principal de Jo (`main`) n'a rien à faire : `lena-auto-commit` fait déjà `git pull --rebase` avant chaque push.

---

## 12. CI rouge sur `main` : « Parite Claude / ChatGPT »

**Symptôme :** le job `ci` échoue à l'étape « Parite Claude / ChatGPT (AGENTS.md, skills) » après une modification de `docs/LENA.md` ou d'un `SKILL.md` sous `.claude/skills`.
**Cause :** `AGENTS.md` (copie pour ChatGPT / Codex, entre `LENA:START` et `LENA:END`) et `.agents/skills` doivent rester identiques à `docs/LENA.md` et `.claude/skills`. On modifie toujours le côté Claude, puis on recopie.

**Réparer (Git Bash, à la racine du checkout) :**
```bash
bash scripts/sync-agents.sh
git add AGENTS.md .agents && git commit -m "sync: AGENTS.md and .agents/skills from Claude sources" && git push
```
Les tâches planifiées ne touchent jamais à ces fichiers : une CI rouge ici ne vient pas d'un snapshot.

---

## Journaux utiles

| Quoi | Où |
|---|---|
| Sauvegarde | `D:\Backups\claude\backup.log` |
| Snapshot + commit + push | `scripts\auto-commit.log` (dans le repo, jamais commité) |
| CI de nuit | `scripts\lena-nightly.log` + sorties de tests `%TEMP%\lena-nightly-*.log` |
| État des tâches | `Get-ScheduledTask lena-*, "Desktop Commander Remote", "Qdrant Vector DB" \| Get-ScheduledTaskInfo` |
