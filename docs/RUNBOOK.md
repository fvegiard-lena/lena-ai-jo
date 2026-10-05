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
Pour la recréer proprement : `pwsh -File scripts\install-tasks.ps1` (met à jour sur place, et relance le process s'il tournait hors de la tâche).

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

## Journaux utiles

| Quoi | Où |
|---|---|
| Sauvegarde | `D:\Backups\claude\backup.log` |
| Snapshot + commit + push | `scripts\auto-commit.log` (dans le repo, jamais commité) |
| CI de nuit | `scripts\lena-nightly.log` + sorties de tests `%TEMP%\lena-nightly-*.log` |
| État des tâches | `Get-ScheduledTask lena-*, "Desktop Commander Remote", "Qdrant Vector DB" \| Get-ScheduledTaskInfo` |
