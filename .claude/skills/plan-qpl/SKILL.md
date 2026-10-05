---
name: plan-qpl
description: Inventaire, bordereau (BOM) et tracé IA des conduits d'un projet Plan Expert (.qpl) de DR Électrique. À utiliser quand Jo demande « inventaire S-xxxx », « BOM S-xxxx », « bordereau », un relevé / décompte de prises, luminaires, conduits ou longueurs, « trace les conduits sur S-xxxx », ou mentionne un code projet du type S-0723 / S-1849 (motif S-\d{3,4}).
---

# plan-qpl — inventaire / bordereau / tracé des conduits Plan Expert

Outil : `%USERPROFILE%\dev\lena-ai-jo\plan-tools`. Les `.qpl` d'origine ne sont jamais modifiés ;
le tracé IA est écrit dans une copie `<nom> - IA.qpl`.
Commandes : **PowerShell (pwsh)** — `$env:USERPROFILE` y est développé ; en Git Bash, remplacer
`"$env:USERPROFILE\dev\…"` par `~/dev/…`.

## Étapes — inventaire / bordereau

1. **Extraire le code projet** du message (motif `S-\d{3,4}`, ex. `S-0723`). S'il manque ou est
   ambigu, demander à Jo le code exact — ne pas deviner.
2. **Générer l'inventaire puis le bordereau** (sortie par défaut dans `%LOCALAPPDATA%`) :
   ```powershell
   uv run --project "$env:USERPROFILE\dev\lena-ai-jo\plan-tools" plan-tools inventory S-0723
   uv run --project "$env:USERPROFILE\dev\lena-ai-jo\plan-tools" plan-tools bom S-0723
   ```
   Chaque commande affiche les chemins des fichiers créés (`CSV : …`). Si l'outil répond
   « Aucun dossier », transmettre le message tel quel à Jo. S'il affiche « Plusieurs dossiers
   trouvés, j'ai pris : … (autres : …) », dire à Jo quel dossier a été utilisé et lesquels ont été
   écartés. « Impossible d'écrire … » : demander à Jo de fermer le fichier (Excel / Plan Expert)
   puis relancer.
3. **Lire le CSV** du bordereau (`…\S-0723 (…).bom.csv`, séparateur `;`, UTF-8 BOM) et, au
   besoin, l'inventaire (`….inventaire.csv`).
4. **Répondre en 3 lignes, en français** :
   - ligne 1 : nombre de plans et de lignes au bordereau ;
   - ligne 2 : principaux comptes (symboles par type, longueurs en px) ;
   - ligne 3 : ce qui est `[À CONFIRMER — Jo]` (plans sans échelle, unité d'échelle, Discipline /
     Modèle laissés vides).
5. **Ouvrir l'Explorateur sur le fichier** :
   ```powershell
   explorer.exe /select,"<chemin complet du .bom.csv>"
   ```

## Étapes — « Léna, trace les conduits sur S-xxxx »

1. **Extraire le code projet** (comme ci-dessus) ; si Jo nomme un plan (« plan R1 - 10 »), le
   passer à `--plan`.
2. **Lancer le tracé** :
   ```powershell
   uv run --project "$env:USERPROFILE\dev\lena-ai-jo\plan-tools" plan-tools route S-0723
   uv run --project "$env:USERPROFILE\dev\lena-ai-jo\plan-tools" plan-tools route S-0723 --plan "R1 - 10"
   ```
   La commande affiche 3 lignes (plans tracés, longueur, chemins). Si elle répond « existe déjà »,
   un tracé précédent est présent : demander à Jo avant de relancer avec `--force`. Si elle répond
   « Aucun symbole à router sur … », le plan demandé n'existe pas ou n'a aucun appareil :
   le dire à Jo et lui demander le nom exact du plan (rien n'a été écrit).
3. **Ouvrir `rapport.md`** (chemin sur la 3e ligne ; bloc « Pour Jo » en tête) et **regarder
   1 ou 2 aperçus** `<plan> - IA.png` du même dossier (≤ 4000 px de large, tracés en magenta).
4. **Répondre en 3 lignes, en français** :
   - ligne 1 : plans tracés, nombre de parcours et d'appareils reliés, longueur totale en px ;
   - ligne 2 : ce qui est `[À CONFIRMER — Jo]` (aucun panneau détecté, étiquettes scindées,
     images introuvables, rôles des symboles dans `config.toml`, unité d'échelle) ;
   - ligne 3 : rappeler que **le .qpl d'origine n'est pas modifié** et que le résultat est
     `<nom> - IA.qpl` (calque « IA - Conduits ») à ouvrir dans Plan Expert pour validation.
5. **Ouvrir l'Explorateur sur le résultat** :
   ```powershell
   explorer.exe /select,"<chemin complet du - IA.qpl>"
   ```
6. Si Jo conteste un rôle (ex. « PANN SOLAIRE n'est pas un panneau »), montrer
   `plan-tools classify-report S-xxxx` et proposer la modification de `config.toml` — sans
   l'appliquer sans son accord.

## Règles

- **Ne jamais passer un chemin OneDrive à `--out`** ; laisser la sortie par défaut
  (`%LOCALAPPDATA%\plan-tools\out\<projet>\`). `--out IA` seulement si Jo le demande explicitement.
- Ne jamais modifier les `.qpl` d'origine ni rien écrire dans le dossier « Mes projets ».
- `--wall-aware` n'est pas implémenté : ne pas l'utiliser ni promettre un contournement des murs.
- Les longueurs sont en **pixels** ; toute conversion d'échelle reste `[À CONFIRMER — Jo]`.
- Ne jamais inventer Discipline, Modèle ou Correction : ces colonnes restent vides.
