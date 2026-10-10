# Simulateur du PC de Jo — prouver avant d'installer

Pour Francis. Règle : **rien n'arrive sur le PC de Jo tant que le simulateur n'est pas vert.**
Le PC de Jo ne reçoit que `main` (`lena-auto-commit` et `lena-nightly-ci` tirent `main` ; les jumeaux,
seulement leur branche) : tout se prouve sur `francis-dev`, puis PR vers `main`.

Les deux simulateurs lancent le même script, `scripts/sim/Test-JoPc.ps1`, qui recrée le PC de Jo sur une
machine Windows **neuve et jetable** et y fait tourner les **vrais** scripts du repo. « origin » y est un dépôt
nu local : rien n'est poussé sur GitHub, le PC de Jo n'est jamais contacté. Le script efface
`%USERPROFILE%\dev` : il refuse de tourner ailleurs que sur un runner GitHub ou dans Windows Sandbox.

## Ce qui est vérifié

| Bloc | Preuve |
|---|---|
| Profil | `%USERPROFILE%\dev\lena-ai-jo` sur `main` = commit testé, `.claude`, OneDrive « Mes projets » avec 2 projets de test, `D:\Backups`, outils mise aux versions de `config/VERSIONS.md`. |
| `install-twin.ps1` | Jumeau `francis-dev` cloné, `CLAUDE.local.md`, lanceur, checkout principal intact. |
| `install-tasks.ps1` | Les 4 tâches créées, RunLevel Limited, bon chemin ; refus depuis un jumeau. |
| `backup-claude.ps1` | Conversation copiée dans `D:\Backups\claude`. |
| `auto-commit.ps1` | Snapshot commité et poussé (vers l'origin local) : seulement `config/` + `INVENTAIRE.md`, aucun nom de compte. |
| `lena-nightly.ps1` | `-DryRun`, run vert, puis un test rouge forcé : sans compte Claude, échec franc et rien de commité ; avec le secret `SIM_ANTHROPIC_API_KEY`, correction réelle. |
| Boucle autonome | `test-lena-loop.sh` et `lena-check.sh` sous **Git Bash Windows**. |
| `plan-tools` | Inventaire, bordereau, tracé sur le faux OneDrive ; `.qpl` d'origine intact ; projet absent = message clair. |

## 1. CI GitHub (automatique)

Workflow `Simulateur PC de Jo` (`.github/workflows/jo-pc-sim.yml`), runner `windows-latest`, à chaque push
sur `francis-dev` / jumeaux et chaque PR vers `main`. Bilan dans le résumé du run, journaux dans l'artefact
`jo-pc-sim-logs`. Limite : Windows Server, session de service (les tâches sont créées, pas déclenchées).

## 2. Windows Sandbox (Windows 11, comme Jo)

Une fois (PowerShell **admin**, puis redémarrer) :

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

Ensuite, depuis le repo :

```powershell
pwsh -File scripts\sim\sandbox\Start-JoPcSandbox.ps1            # branche francis-dev
```

La Sandbox installe Git, PowerShell 7, mise et Claude Code, clone la branche depuis GitHub, lance
`Test-JoPc.ps1`, puis **déclenche les vraies tâches planifiées** dans une session interactive (comme chez Jo)
et vérifie leur code de retour. Verdict dans `%USERPROFILE%\lena-sim\out\verdict.txt`.

Test avec le vrai Claude (optionnel, plafond 1 $) : dans la Sandbox, `claude` puis `/login`, puis
`pwsh -File C:\sim\host\Start-RealLoop.ps1` → une vraie tâche passe par la boucle ; verdict dans
`out\real-loop-verdict.txt`. La Sandbox s'efface à la fermeture (login compris).

## Ce qu'aucun simulateur ne prouve

Outlook / OST, le vrai OneDrive (371 `.qpl`), le compte claude.ai de Jo et ses connecteurs, l'appairage
Desktop Commander : ils n'existent que sur le PC de Jo.
